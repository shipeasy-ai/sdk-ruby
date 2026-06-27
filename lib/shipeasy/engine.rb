require "net/http"
require "uri"
require "json"
require "thread"
require "cgi"
require_relative "sdk/eval"
require_relative "sdk/telemetry"
require_relative "sdk/anon_id"
require_relative "sdk/sticky_store"
require_relative "sdk/see"

module Shipeasy
  # The heavyweight engine: owns the api key, HTTP transport, the blob cache,
  # the background poll timer, init/init_once, local overrides, track, and
  # see()/default-client wiring. Was `Shipeasy::SDK::FlagsClient` before 2.0;
  # renamed to a clean top-level `Shipeasy::Engine` when the lightweight
  # user-bound `Shipeasy::Client` became the primary front door.
  #
  # Most apps never construct an Engine directly — `Shipeasy.configure { … }`
  # builds and registers the one global engine for you. Construct one explicitly
  # only for advanced/serverless flows (multiple keys, offline snapshots).
  class Engine
      # Internal collaborators still live under Shipeasy::SDK; alias them so the
      # body below can keep referring to them unqualified after the class moved
      # out from under the SDK namespace.
      Eval      = Shipeasy::SDK::Eval
      Telemetry = Shipeasy::SDK::Telemetry
      AnonId    = Shipeasy::SDK::AnonId
      See       = Shipeasy::SDK::See

      DEFAULT_BASE_URL = "https://edge.shipeasy.dev"
      # CDN origin serving the static loader scripts (/sdk/bootstrap.js,
      # /sdk/i18n/loader.js) — distinct from the edge API the blobs are fetched from.
      DEFAULT_CDN_BASE = "https://cdn.shipeasy.ai"

      def initialize(api_key:, base_url: nil, env: "prod", disable_telemetry: false, telemetry_url: nil, test_mode: false, private_attributes: nil, sticky_store: nil)
        @api_key     = api_key
        @base_url    = (base_url || DEFAULT_BASE_URL).chomp("/")
        # Read-env tag. Used by telemetry below and stamped onto see() error
        # events so reports are attributable to an environment.
        @env         = env
        # Attribute names usable for targeting but stripped from every outbound
        # /collect payload (LD/Statsig privateAttributes). The server evaluates
        # locally so private attrs never leave for evaluation; the only egress is
        # track(), where the listed keys are dropped from the props bag.
        @private_attributes = (private_attributes || []).map(&:to_s)
        # Pluggable sticky-bucketing store (doc 20 §2). Absent ⇒ deterministic.
        # Threaded into get_experiment so an enrolled unit locks to its first
        # assigned variant. Built-in: InMemoryStickyStore.
        @sticky_store = sticky_store
        # Test mode: no network, ever. init/init_once/track become no-ops and
        # evaluation answers come purely from local overrides. Built via the
        # Engine.for_testing factory; see clear_overrides / override_*.
        @test_mode   = test_mode
        # Per-evaluation usage telemetry. ON by default; pass
        # disable_telemetry: true to opt out. See telemetry.rb.
        @telemetry = Telemetry.new(
          endpoint: telemetry_url || Telemetry::DEFAULT_TELEMETRY_URL,
          sdk_key: api_key,
          side: "server",
          env: env,
          disabled: disable_telemetry,
        )
        @flags_blob  = nil
        @exps_blob   = nil
        @flags_etag  = nil
        @exps_etag   = nil
        @poll_interval = 30
        @mutex       = Mutex.new
        @timer       = nil
        @initialized = false
        # Statsig-style local overrides. Keyed by resource name; an override,
        # when present, short-circuits the corresponding getter. Usable on any
        # client (test or live) for deterministic tests / local development.
        @flag_overrides   = {}
        @config_overrides = {}
        @exp_overrides    = {}
        # Change listeners — fired after a background poll returns NEW data
        # (HTTP 200, not 304). Never fired in test/offline mode. Guarded by
        # @mutex; see on_change / notify_change.
        @change_listeners = []
        # see() structured error reporting. Per-process spam guard, bound here so
        # repeated reports of the same issue collapse to one send. See see.rb.
        @see_limiter = See::Limiter.new
        # Register as the default client backing the module-level Shipeasy::SDK
        # .see/.see_violation funcs (last constructed wins — the server-SDK
        # analog of TS's shipeasy({key}) configure call).
        Shipeasy::SDK.set_default_client(self)
      end

      # Build a no-network, immediately-usable client for tests. Telemetry is
      # disabled, init/init_once/track are no-ops (never fetch), and no api_key
      # is required. The client is immediately READY against an empty blob (so a
      # missing gate resolves FLAG_NOT_FOUND, not CLIENT_NOT_READY — parity with
      # the other SDKs). Seed it with override_flag / override_config /
      # override_experiment, then call the normal getters.
      def self.for_testing(env: "prod")
        client = new(
          api_key: "test",
          env: env,
          disable_telemetry: true,
          test_mode: true,
        )
        client.send(:load_snapshot, {}, {})
        client
      end

      # Build an offline client from a JSON snapshot file. The file holds the
      # raw response bodies of the two SDK endpoints under "flags" and
      # "experiments" keys:
      #
      #   { "flags": <body of /sdk/flags>, "experiments": <body of /sdk/experiments> }
      #
      # The returned client does ZERO network (reuses test_mode plumbing:
      # init/init_once/track are no-ops, telemetry off) but, unlike a bare
      # for_testing client, runs the REAL evaluator against the loaded blobs.
      # Local overrides still apply on top. Handy for CI, air-gapped runs, and
      # reproducing a production decision from a captured blob.
      def self.from_file(path, env: "prod")
        data = JSON.parse(File.read(path))
        from_snapshot(flags: data["flags"], experiments: data["experiments"], env: env)
      end

      # Build an offline client directly from already-parsed blobs (same shape
      # as the /sdk/flags and /sdk/experiments response bodies). See from_file.
      def self.from_snapshot(flags: nil, experiments: nil, env: "prod")
        client = for_testing(env: env)
        client.send(:load_snapshot, flags, experiments)
        client
      end

      def init
        return if @test_mode
        fetch_all
        @initialized = true
        start_poll
      end

      def init_once
        return if @test_mode
        return if @initialized
        fetch_all
        @initialized = true
      end

      # --- Local overrides -------------------------------------------------
      # An override wins over the fetched blob in the matching getter. Setters
      # are mutex-guarded so they're safe to call alongside background polling
      # on a live client.

      def override_flag(name, value)
        @mutex.synchronize { @flag_overrides[name.to_s] = (value ? true : false) }
        self
      end

      def override_config(name, value)
        @mutex.synchronize { @config_overrides[name.to_s] = value }
        self
      end

      def override_experiment(name, group, params)
        @mutex.synchronize do
          @exp_overrides[name.to_s] = { group: group, params: params }
        end
        self
      end

      def clear_overrides
        @mutex.synchronize do
          @flag_overrides.clear
          @config_overrides.clear
          @exp_overrides.clear
        end
        self
      end

      # Register a listener fired after a background poll fetches NEW flag/config
      # data (HTTP 200, not 304). Accepts either a block or any callable (an
      # object responding to #call). Returns an unsubscribe proc — call it to
      # remove the listener. Never fires in test/offline mode (no poll thread).
      def on_change(callable = nil, &block)
        listener = callable || block
        raise ArgumentError, "on_change requires a block or callable" unless listener.respond_to?(:call)
        @mutex.synchronize { @change_listeners << listener }
        proc { @mutex.synchronize { @change_listeners.delete(listener) } }
      end

      def destroy
        @timer&.kill
        @timer = nil
      end

      # Flag evaluation with the reason the value was reached. :value is the
      # boolean result; :reason is one of the REASON_* constants below.
      FlagDetail = Struct.new(:value, :reason, keyword_init: true)

      # Reason constants for FlagDetail#reason / get_flag_detail.
      REASON_CLIENT_NOT_READY = "CLIENT_NOT_READY" # no blob fetched/loaded yet
      REASON_FLAG_NOT_FOUND   = "FLAG_NOT_FOUND"   # blob present, gate absent
      REASON_OFF              = "OFF"              # gate present but disabled/killed
      REASON_OVERRIDE         = "OVERRIDE"         # answered by a local override
      REASON_RULE_MATCH       = "RULE_MATCH"       # evaluated true
      REASON_DEFAULT          = "DEFAULT"          # evaluated false (rollout/rule)

      # Evaluate a flag and return why. Telemetry ("gate" beacon) is emitted
      # exactly once here (steps 2–5), never on the OVERRIDE short-circuit.
      def get_flag_detail(name, user)
        key = name.to_s

        # 1. Override short-circuits before any telemetry (mirrors get_config).
        override = @mutex.synchronize { @flag_overrides[key] if @flag_overrides.key?(key) }
        return FlagDetail.new(value: override, reason: REASON_OVERRIDE) unless override.nil?

        @telemetry.emit("gate", name)

        flags_blob, gate = @mutex.synchronize { [@flags_blob, @flags_blob&.dig("gates", name)] }

        # 2. Not initialized — no blob fetched or loaded yet.
        return FlagDetail.new(value: false, reason: REASON_CLIENT_NOT_READY) if flags_blob.nil?

        # 3. Blob present but this gate isn't in it.
        return FlagDetail.new(value: false, reason: REASON_FLAG_NOT_FOUND) unless gate

        # 4. Gate present but disabled (or killswitched) — eval_gate would also
        #    return false here, but the reason is OFF, not a rollout DEFAULT.
        if Eval.enabled?(gate["killswitch"]) || !Eval.enabled?(gate["enabled"])
          return FlagDetail.new(value: false, reason: REASON_OFF)
        end

        # 5. Run the canonical evaluator; reason follows the boolean result.
        result = Eval.eval_gate(gate, with_anon_id(user))
        FlagDetail.new(value: result, reason: result ? REASON_RULE_MATCH : REASON_DEFAULT)
      end

      def get_flag(name, user, default: false)
        detail = get_flag_detail(name, user)
        if detail.reason == REASON_CLIENT_NOT_READY || detail.reason == REASON_FLAG_NOT_FOUND
          default
        else
          detail.value
        end
      end

      def get_config(name, decode = nil, default: nil)
        key = name.to_s
        has_override, override = @mutex.synchronize do
          [@config_overrides.key?(key), @config_overrides[key]]
        end
        if has_override
          return decode ? decode.call(override) : override
        end

        @telemetry.emit("config", name)
        entry = @mutex.synchronize { @flags_blob&.dig("configs", name) }
        return default unless entry
        value = entry["value"]
        decode ? decode.call(value) : value
      end

      def get_experiment(name, user, default_params, decode = nil)
        key = name.to_s
        override = @mutex.synchronize { @exp_overrides[key] }
        if override
          params = override[:params]
          params = decode.call(params) if decode
          return Eval::ExperimentResult.new(
            in_experiment: true,
            group: override[:group],
            params: params,
          )
        end

        @telemetry.emit("experiment", name)
        flags_blob, exps_blob = @mutex.synchronize { [@flags_blob, @exps_blob] }
        exp = exps_blob&.dig("experiments", name)
        result = Eval.eval_experiment(
          exp, flags_blob, exps_blob, with_anon_id(user),
          exp_name: name.to_s, sticky_store: @sticky_store,
        )
        result.params ||= default_params

        if result.in_experiment && decode
          begin
            result = Eval::ExperimentResult.new(
              in_experiment: true,
              group: result.group,
              params: decode.call(result.params),
            )
          rescue => e
            warn "[shipeasy] get_experiment('#{name}') decode failed: #{e.message}"
            return Eval::ExperimentResult.new(in_experiment: false, group: "control", params: default_params)
          end
        end

        result
      end

      # Public hook for the bound Shipeasy::Client: normalise an attribute hash
      # and apply the request-scoped anonymous_id merge ONCE, at Client
      # construction, exactly as every per-call getter does internally.
      def bind_attributes(user)
        with_anon_id(user)
      end

      # Read a killswitch from the cached flags blob. Without +switch_key+,
      # returns true when the whole killswitch is killed. With +switch_key+,
      # returns true when that specific named per-key switch is on — and when
      # the key isn't configured on the killswitch, FALLS BACK to the top-level
      # value (so an unconfigured key behaves exactly like the no-key call).
      # Unknown killswitches return false. Not user-scoped.
      def get_killswitch(name, switch_key = nil)
        @telemetry.emit("ks", name)
        ks = @mutex.synchronize { @flags_blob&.dig("killswitches", name.to_s) }
        return false unless ks
        unless switch_key.nil?
          switches = ks["switches"] || {}
          key = switch_key.to_s
          return Eval.enabled?(switches[key]) if switches.key?(key)
          # key not configured → fall through to the top-level value
        end
        Eval.enabled?(ks["killed"])
      end

      # Batch-evaluate every loaded gate, config and experiment for +user+ into
      # a bootstrap payload (+{ "flags" => ..., "configs" => ..., "experiments"
      # => ..., "killswitches" => ... }+) keyed to match the browser SDK's
      # window.__SE_BOOTSTRAP shape. Local overrides win. Killswitches are folded
      # into per-gate evaluation, so the standalone +killswitches+ map is empty
      # for this SDK. No telemetry (a batch evaluate is not a per-flag exposure).
      def evaluate(user)
        u = with_anon_id(user)
        flags_blob, exps_blob, flag_ov, config_ov, exp_ov, sticky = @mutex.synchronize do
          [@flags_blob, @exps_blob, @flag_overrides.dup, @config_overrides.dup,
           @exp_overrides.dup, @sticky_store]
        end

        flags = {}
        (flags_blob&.dig("gates") || {}).each do |name, gate|
          flags[name] = flag_ov.key?(name) ? flag_ov[name] : Eval.eval_gate(gate, u)
        end

        configs = {}
        (flags_blob&.dig("configs") || {}).each do |name, entry|
          configs[name] = config_ov.key?(name) ? config_ov[name] : entry["value"]
        end

        experiments = {}
        (exps_blob&.dig("experiments") || {}).each do |name, exp|
          if exp_ov.key?(name)
            ov = exp_ov[name]
            experiments[name] = { "inExperiment" => true, "group" => ov[:group], "params" => ov[:params] }
            next
          end
          r = Eval.eval_experiment(exp, flags_blob, exps_blob, u, exp_name: name, sticky_store: sticky)
          experiments[name] = { "inExperiment" => r.in_experiment, "group" => r.group, "params" => r.params }
        end

        { "flags" => flags, "configs" => configs, "experiments" => experiments, "killswitches" => {} }
      end

      # Return the cross-platform SSR bootstrap <script> tag for a request:
      # se-bootstrap.js reads its data-* attributes and hydrates
      # window.__SE_BOOTSTRAP (and writes the anon cookie). No key is embedded.
      def bootstrap_script_tag(user, anon_id: nil, i18n_profile: "en:prod", base_url: nil)
        payload = evaluate(user)
        base = cdn_base(base_url)
        attrs = [
          "data-se-bootstrap",
          attr("data-flags", JSON.generate(payload["flags"])),
          attr("data-configs", JSON.generate(payload["configs"])),
          attr("data-experiments", JSON.generate(payload["experiments"])),
          attr("data-killswitches", JSON.generate(payload["killswitches"])),
          attr("data-i18n-profile", i18n_profile || "en:prod"),
          attr("data-api-url", base),
        ]
        attrs << attr("data-anon-id", anon_id) if anon_id && !anon_id.empty?
        %(<script src="#{CGI.escapeHTML("#{base}/sdk/bootstrap.js")}" #{attrs.join(' ')}></script>)
      end

      # Return the i18n loader <script> tag (framework-agnostic; the Rails view
      # helper Shipeasy::I18n::ViewHelpers#i18n_script_tag is separate). The
      # loader fetches translations for the profile using the PUBLIC client key.
      def i18n_script_tag(client_key, profile: "en:prod", base_url: nil)
        base = cdn_base(base_url)
        %(<script src="#{CGI.escapeHTML("#{base}/sdk/i18n/loader.js")}" ) +
          %(#{attr('data-key', client_key)} #{attr('data-profile', profile || 'en:prod')}></script>)
      end

      def track(user_id, event_name, props = {})
        return if @test_mode

        safe_props = strip_private(props)

        payload = JSON.generate({
          events: [{
            type: "metric",
            event_name: event_name,
            user_id: user_id.to_s,
            ts: (Time.now.to_f * 1000).to_i,
            **(safe_props.empty? ? {} : { properties: safe_props }),
          }],
        })

        Thread.new do
          post("/collect", payload)
        rescue => e
          warn "[shipeasy] track failed: #{e.message}"
        end
      end

      # Emit an exposure event for an experiment at the server-side decision
      # point (parity with the browser's auto-exposure). The server is stateless
      # and never auto-logs, so call this when you actually present the
      # treatment. Re-evaluates the experiment for the user (a bare user_id
      # string is wrapped as { "user_id" => id }); if enrolled, POSTs a single
      # exposure to /collect. No-op in test mode or when the user isn't enrolled.
      def log_exposure(user_or_user_id, experiment_name)
        return if @test_mode

        user = user_or_user_id.is_a?(Hash) ? user_or_user_id : { "user_id" => user_or_user_id.to_s }
        result = get_experiment(experiment_name, user, {})
        return unless result.in_experiment

        u = user.transform_keys(&:to_s)
        payload = JSON.generate({
          events: [{
            type: "exposure",
            experiment: experiment_name.to_s,
            group: result.group,
            user_id: (u["user_id"] || u["anonymous_id"]).to_s,
            ts: (Time.now.to_f * 1000).to_i,
          }],
        })

        Thread.new do
          post("/collect", payload)
        rescue => e
          warn "[shipeasy] log_exposure failed: #{e.message}"
        end
      end

      # ---- see() structured error reporting -------------------------------

      # Report a caught exception (or thrown non-exception). Fire-and-forget;
      # never blocks or throws into the request path. Terminate with
      # `.to(outcome)`:
      #
      #   client.see(e).causes_the("checkout").to("use cached prices")
      def see(problem)
        See::Chain.new(problem, method(:dispatch_see))
      end

      # Report a non-exception problem. The name is a stable fingerprint key —
      # put variable data in `.extras`, never in the name.
      def see_violation(name)
        See::Chain.new(See::Violation.new(name), method(:dispatch_see))
      end
      alias seeViolation see_violation

      # Mark an exception as expected control flow — reports nothing. Returns a
      # `.because(reason)` tail (with optional `.extras` for local debug only).
      def control_flow_exception(err)
        See::ControlFlowChain.new(err)
      end
      alias controlFlowException control_flow_exception

      private

      # Build the wire event and fire-and-forget POST it to /collect. No-op in
      # test mode (mirrors track). Spam-guarded. Never raises into caller code.
      def dispatch_see(built)
        return if @test_mode

        ev = See.build_event(
          built.problem,
          built.subject,
          built.outcome,
          strip_private(built.extras),
          sdk_version: Shipeasy::SDK::VERSION,
          env: @env,
        )
        return unless @see_limiter.should_send?(ev)

        payload = JSON.generate({ events: [ev] })
        Thread.new do
          post("/collect", payload)
        rescue => e
          warn "[shipeasy] see() send failed: #{e.message}"
        end
      rescue => e
        warn "[shipeasy] see() failed: #{e.message}"
      end

      # Drop caller-marked private attributes from an outbound props bag. Handles
      # both string and symbol keys against the stringified private list.
      def strip_private(props)
        return props if props.nil? || props.empty? || @private_attributes.empty?
        props.reject { |k, _| @private_attributes.include?(k.to_s) }
      end

      # Load a parsed snapshot into the local blobs and mark the client ready,
      # without any network. Used by from_snapshot / from_file on a test_mode
      # client so the real evaluator runs against captured data.
      def load_snapshot(flags, experiments)
        @mutex.synchronize do
          @flags_blob = flags
          @exps_blob  = experiments
        end
        @initialized = true
        self
      end

      # Fire each change listener, snapshotting the array under the mutex so a
      # listener that unsubscribes mid-callback doesn't mutate the list we're
      # iterating. Listener errors are isolated (warn, never propagate).
      def notify_change
        listeners = @mutex.synchronize { @change_listeners.dup }
        listeners.each do |listener|
          begin
            listener.call
          rescue => e
            warn "[shipeasy] on_change listener raised: #{e.message}"
          end
        end
      end

      # Normalise the user hash to string keys and, when the caller passed no
      # explicit unit, default anonymous_id to the request's __se_anon_id (set by
      # RackMiddleware). Lets `get_flag("x", {})` bucket anonymous traffic with
      # zero per-call wiring. A caller-supplied user_id/anonymous_id always wins.
      def with_anon_id(user)
        u = user.transform_keys(&:to_s)
        has_unit = !blank?(u["user_id"]) || !blank?(u["anonymous_id"])
        unless has_unit
          anon = AnonId.current
          u["anonymous_id"] = anon if anon
        end
        u
      end

      def blank?(v)
        v.nil? || v == ""
      end

      def cdn_base(override)
        (override && !override.empty? ? override : DEFAULT_CDN_BASE).chomp("/")
      end

      def attr(name, value)
        %(#{name}="#{CGI.escapeHTML(value.to_s)}")
      end

      def start_poll
        @timer = Thread.new do
          loop do
            sleep(@poll_interval)
            begin
              fetch_all
            rescue => e
              warn "[shipeasy] background poll failed: #{e.message}"
            end
          end
        end
        @timer.abort_on_exception = false
      end

      def fetch_all
        flags_thread = Thread.new { fetch_flags }
        fetch_exps
        interval = flags_thread.value
        if interval && interval != @poll_interval
          @poll_interval = interval
        end
      end

      def fetch_flags
        headers = { "X-SDK-Key" => @api_key }
        headers["If-None-Match"] = @flags_etag if @flags_etag
        res = http_get("/sdk/flags", headers)
        interval = (res["X-Poll-Interval"] || "30").to_i
        return interval if res.code == "304"
        raise "GET /sdk/flags returned #{res.code}" unless res.is_a?(Net::HTTPSuccess)
        etag = res["ETag"]
        blob = JSON.parse(res.body)
        @mutex.synchronize do
          @flags_etag = etag if etag
          @flags_blob = blob
        end
        # New data arrived (200, not the 304 returned above) — notify listeners.
        notify_change
        interval
      end

      def fetch_exps
        headers = { "X-SDK-Key" => @api_key }
        headers["If-None-Match"] = @exps_etag if @exps_etag
        res = http_get("/sdk/experiments", headers)
        return if res.code == "304"
        raise "GET /sdk/experiments returned #{res.code}" unless res.is_a?(Net::HTTPSuccess)
        etag = res["ETag"]
        blob = JSON.parse(res.body)
        @mutex.synchronize do
          @exps_etag = etag if etag
          @exps_blob = blob
        end
      end

      def http_get(path, headers = {})
        uri  = URI.parse("#{@base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl     = (uri.scheme == "https")
        http.open_timeout = 5
        http.read_timeout = 10
        http.get(uri.request_uri, headers)
      end

      def post(path, body)
        uri  = URI.parse("#{@base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == "https")
        http.open_timeout = 5
        http.read_timeout = 10
        http.post(uri.request_uri, body, { "X-SDK-Key" => @api_key, "Content-Type" => "text/plain" })
      end
  end
end
