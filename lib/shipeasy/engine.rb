require "net/http"
require "uri"
require "json"
require "thread"
require "cgi"
require_relative "logging"
require_relative "sdk/env"
require_relative "sdk/eval"
require_relative "sdk/telemetry"
require_relative "sdk/anon_id"
require_relative "sdk/sticky_store"
require_relative "sdk/see"
require_relative "sdk/internal_report"

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

      DEFAULT_BASE_URL = "https://api.shipeasy.ai"
      # CDN origin serving the static loader scripts (/sdk/bootstrap.js,
      # /sdk/i18n/loader.js) — distinct from the edge API the blobs are fetched from.
      DEFAULT_CDN_BASE = "https://cdn.shipeasy.ai"

      def initialize(api_key:, base_url: nil, env: "prod", is_network_enabled: nil, disable_telemetry: nil, telemetry_url: nil, test_mode: false, private_attributes: nil, sticky_store: nil, log_level: nil, disable_internal_error_reporting: false, clean_backtrace: true)
        # SDK-wide diagnostic verbosity. Set the leveled logger from the passed
        # level (default :warn; unknown falls back to :warn). The logger is
        # module-scoped, so the last-built engine wins — mirrors the TS SDK,
        # where the last configure() sets the level.
        Shipeasy::Logging.set_level(log_level || Shipeasy::Logging::DEFAULT_LEVEL)
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
        # When true (default), see() error stacks are passed through the host
        # framework's own backtrace cleaner so a report carries only application
        # frames (gem/framework noise stripped). We never invent the filtering —
        # today this leverages Rails.backtrace_cleaner and is a no-op outside
        # Rails. Set false to always send the raw backtrace. See
        # see_backtrace_cleaner.
        @clean_backtrace = clean_backtrace != false
        # Pluggable sticky-bucketing store (doc 20 §2). Absent ⇒ deterministic.
        # Threaded into experiment eval so an enrolled unit locks to its first
        # assigned variant. Built-in: InMemoryStickyStore.
        @sticky_store = sticky_store
        # Test mode: no network, ever. init/init_once/track become no-ops and
        # evaluation answers come purely from local overrides. Built via the
        # Engine.for_testing factory; see clear_overrides / override_*.
        @test_mode   = test_mode
        # Environment-derived egress default. Both the master network switch and
        # usage telemetry default ON in production and OFF everywhere else, so an
        # app that embeds the SDK is quiet by default on a dev machine or in CI.
        # The production decision consults native env vars first (SHIPEASY_ENV /
        # RAILS_ENV / RACK_ENV / APP_ENV), then falls back to the configured `env`
        # tag. See sdk/env.rb.
        prod = Shipeasy::SDK::Env.is_production_env(env)
        # Master network gate. test_mode always forces the SDK fully offline;
        # otherwise honour an explicit is_network_enabled, else default to
        # prod-on. When @offline, every fetch / track / exposure / see() / poll /
        # telemetry send is a no-op — reads answer from overrides / in-code
        # defaults only.
        network_enabled = @test_mode ? false : (is_network_enabled.nil? ? prod : (is_network_enabled ? true : false))
        @offline = !network_enabled
        # Per-evaluation usage telemetry. Honour an explicit disable_telemetry,
        # else default to prod-on (off outside production). Forced off whenever
        # the master network switch is off. See telemetry.rb.
        telemetry_disabled = @offline || (disable_telemetry.nil? ? !prod : (disable_telemetry ? true : false))
        @telemetry = Telemetry.new(
          endpoint: telemetry_url || Telemetry::DEFAULT_TELEMETRY_URL,
          sdk_key: api_key,
          side: "server",
          env: env,
          disabled: telemetry_disabled,
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
        # Auto-exposure dedup set: assign() logs a single exposure per
        # (unit, experiment, group) so repeated assigns in one process don't spam
        # /collect. Bounded — cleared when it grows past ~5000 keys.
        @exposure_seen = {}
        # Self-monitoring channel: when safe_run swallows one of the SDK's OWN
        # internal errors, it also ships a see event to Shipeasy's own project
        # (a baked-in destination, distinct from the consumer's see() path) so
        # the SDK team can track SDK bugs across every app. Fire-and-forget,
        # never raises. On by default; forced off in test mode (no network) and
        # opt-out-able via disable_internal_error_reporting. Module-scoped, so
        # the last-built engine wins — mirrors set_level / the TS reference.
        Shipeasy::SDK::InternalReport.set_context(
          side: "server",
          sdk_version: Shipeasy::SDK::VERSION,
          enabled: !@offline && !disable_internal_error_reporting,
        )
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
        return if @offline
        fetch_all
        @initialized = true
        start_poll
      end

      def init_once
        return if @offline
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
        safe_run("get_flag_detail('#{name}')", FlagDetail.new(value: false, reason: REASON_CLIENT_NOT_READY)) do
          get_flag_detail_inner(name, user)
        end
      end

      def get_flag_detail_inner(name, user)
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
        safe_run("get_flag('#{name}')", default) do
          detail = get_flag_detail(name, user)
          if detail.reason == REASON_CLIENT_NOT_READY || detail.reason == REASON_FLAG_NOT_FOUND
            default
          else
            detail.value
          end
        end
      end

      def get_config(name, decode = nil, default: nil)
        safe_run("get_config('#{name}')", default) do
          key = name.to_s
          has_override, override = @mutex.synchronize do
            [@config_overrides.key?(key), @config_overrides[key]]
          end
          if has_override
            begin
              next(decode ? decode.call(override) : override)
            rescue => e
              Shipeasy::Logging.warn "[shipeasy] get_config('#{name}') decode failed: #{e.message}"
              next default
            end
          end

          @telemetry.emit("config", name)
          entry = @mutex.synchronize { @flags_blob&.dig("configs", name) }
          next default unless entry
          value = entry["value"]
          begin
            decode ? decode.call(value) : value
          rescue => e
            Shipeasy::Logging.warn "[shipeasy] get_config('#{name}') decode failed: #{e.message}"
            default
          end
        end
      end

      # Assign +user+ within +universe_name+. A universe is a mutual-exclusion
      # pool, so a unit lands in AT MOST ONE experiment; the returned
      # Eval::Assignment exposes the variant + resolved params and auto-logs a
      # single exposure when enrolled. An un-enrolled unit still resolves get()
      # to the universe defaults. Never raises. This is the sole experiment read
      # path — there is no get_experiment (a caller asks a universe, not an
      # experiment). Internal: the public surface is universe(name).assign(user).
      def assign_universe(universe_name, user)
        empty = Eval::Assignment.new(nil, nil, {})
        safe_run("assign_universe('#{universe_name}')", empty) do
          @telemetry.emit("experiment", universe_name)
          u = with_anon_id(user)
          flags_blob, exps_blob = @mutex.synchronize { [@flags_blob, @exps_blob] }

          universe = exps_blob&.dig("universes", universe_name.to_s)
          param_defaults = Eval.param_defaults_from_schema(
            universe && (universe["param_schema"] || universe[:param_schema])
          )
          not_enrolled = Eval::Assignment.new(nil, nil, param_defaults || {})
          next not_enrolled unless exps_blob

          # Candidate running experiments in this universe. Deterministic order:
          # pool-slice offset asc (slices are disjoint so <=1 matches under
          # pooling), then name. A universe-held-out or unallocated unit falls
          # through to the defaults-only handle.
          candidates = (exps_blob["experiments"] || {}).select do |_name, exp|
            exp["universe"] == universe_name.to_s && exp["status"] == "running"
          end.sort_by { |name, exp| [(exp["poolOffsetBp"] || 0), name] }

          landed = nil
          candidates.each do |name, exp|
            result = eval_experiment(name, exp, u, flags_blob, exps_blob)
            next unless result.in_experiment
            group = result.group
            # On-read exposure (spec step 7): defer the single exposure to the
            # first param read via the callback, instead of firing it here at
            # assign time.
            landed = Eval::Assignment.new(name, group, result.params || {}, lambda {
              post_exposure(u, name, group)
            })
            break
            # not enrolled: try the next candidate — under pooling only one slice
            # can match, so the loop lands on the winner (or falls through).
          end

          landed || not_enrolled
        end
      end

      # A reusable handle bound to one universe. +assign(user)+ picks the <=1
      # experiment the unit is pooled into and auto-logs a single exposure. See
      # assign_universe.
      def universe(name)
        UniverseHandle.new(self, name)
      end

      # Returned by Engine#universe. Binds a universe name so callers can reuse
      # the handle: `engine.universe("checkout").assign(user)`.
      class UniverseHandle
        def initialize(engine, name)
          @engine = engine
          @name   = name
        end

        def assign(user)
          @engine.assign_universe(@name, user)
        end
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
        safe_run("get_killswitch('#{name}')", false) do
          @telemetry.emit("ks", name)
          ks = @mutex.synchronize { @flags_blob&.dig("killswitches", name.to_s) }
          next false unless ks
          unless switch_key.nil?
            switches = ks["switches"] || {}
            key = switch_key.to_s
            next Eval.enabled?(switches[key]) if switches.key?(key)
            # key not configured → fall through to the top-level value
          end
          Eval.enabled?(ks["killed"])
        end
      end

      # Batch-evaluate every loaded gate, config and experiment for +user+ into
      # a bootstrap payload (+{ "flags" => ..., "configs" => ..., "experiments"
      # => ..., "killswitches" => ... }+) keyed to match the browser SDK's
      # window.__SE_BOOTSTRAP shape. Local overrides win. Killswitches are folded
      # into per-gate evaluation, so the standalone +killswitches+ map is empty
      # for this SDK. No telemetry (a batch evaluate is not a per-flag exposure).
      def evaluate(user)
        u = with_anon_id(user)
        flags_blob, exps_blob, flag_ov, config_ov = @mutex.synchronize do
          [@flags_blob, @exps_blob, @flag_overrides.dup, @config_overrides.dup]
        end

        flags = {}
        (flags_blob&.dig("gates") || {}).each do |name, gate|
          flags[name] = flag_ov.key?(name) ? flag_ov[name] : Eval.eval_gate(gate, u)
        end

        configs = {}
        (flags_blob&.dig("configs") || {}).each do |name, entry|
          configs[name] = config_ov.key?(name) ? config_ov[name] : entry["value"]
        end

        # Per-experiment result carries the universe name; a top-level universes
        # map exposes each universe's param defaults so the client can resolve
        # universe(name).get() to a default even when the unit is not enrolled.
        experiments = {}
        universes = {}
        (exps_blob&.dig("experiments") || {}).each do |name, exp|
          uni_name = exp["universe"]
          unless universes.key?(uni_name)
            uni = exps_blob&.dig("universes", uni_name)
            universes[uni_name] = {
              "defaults" => Eval.param_defaults_from_schema(uni && (uni["param_schema"] || uni[:param_schema])) || {},
            }
          end
          r = eval_experiment(name, exp, u, flags_blob, exps_blob, emit_telemetry: false)
          experiments[name] = {
            "inExperiment" => r.in_experiment,
            "group" => r.in_experiment ? r.group : "control",
            "params" => r.in_experiment ? (r.params || {}) : {},
            "universe" => uni_name,
          }
        end

        { "flags" => flags, "configs" => configs, "experiments" => experiments,
          "killswitches" => {}, "universes" => universes }
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
        data_user = identity_attrs(user)
        attrs << attr("data-user", data_user) if data_user
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
        safe_run("track('#{event_name}')", nil) do
          next if @offline

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
            Shipeasy::Logging.warn "[shipeasy] track failed: #{e.message}"
          end
          nil
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

      # Last-resort guard that makes a public RUNTIME method (get_flag /
      # get_config / assign_universe / get_killswitch / track) unable to raise
      # into product code, even if an internal invariant is
      # violated. Runs the block; on any StandardError it logs at :error and
      # returns +fallback+ (the method's documented safe default). +label+ names
      # the method for the log line.
      def safe_run(label, fallback)
        yield
      rescue StandardError => e
        Shipeasy::Logging.error "[shipeasy] #{label} failed — returning safe default: #{e.message}"
        # A caught error here is by definition "on our end" — an internal SDK
        # failure, not the caller's — so in addition to logging locally it is
        # reported to Shipeasy's own project via the self-monitoring channel
        # (fire-and-forget, never raises). The label's stable stem (e.g.
        # "get_flag" from "get_flag('new_checkout')") is the issue subject, so
        # occurrences of the same bug dedupe regardless of the resource name.
        Shipeasy::SDK::InternalReport.report(internal_subject(label), e)
        fallback
      end

      # The stable subject for an internal-error report: strip the variable
      # "('resource')" argument off a safe_run label so the fingerprint carries
      # no variable data and identical bugs dedupe into one issue.
      def internal_subject(label)
        label.to_s.sub(/\(.*\)\z/, "")
      end

      # Evaluate one experiment by name for +user+ — override -> full classify
      # pipeline (targeting -> universe holdout -> holdout gate -> sticky ->
      # allocation -> group), merging the universe defaults under the assigned
      # variant. Returns an Eval::ExperimentResult. Reused by assign_universe and
      # the SSR evaluate() bootstrap (keyed by experiment name). Emits the
      # per-experiment telemetry beacon exactly once (never on the override
      # short-circuit), unless +emit_telemetry+ is false (the batch evaluate()
      # path is not a per-experiment exposure). +user+ is expected pre-normalised
      # (with_anon_id).
      def eval_experiment(name, exp, user, flags_blob, exps_blob, emit_telemetry: true)
        key = name.to_s
        override = @mutex.synchronize { @exp_overrides[key] }
        if override
          universe = exps_blob&.dig("universes", exp && exp["universe"])
          param_defaults = Eval.param_defaults_from_schema(
            universe && (universe["param_schema"] || universe[:param_schema])
          )
          return Eval::ExperimentResult.new(
            in_experiment: true,
            group: override[:group],
            params: Eval.merge_params(param_defaults, override[:params]),
          )
        end

        @telemetry.emit("experiment", name) if emit_telemetry
        Eval.eval_experiment(
          exp, flags_blob, exps_blob, user,
          exp_name: key, sticky_store: @sticky_store,
        )
      end

      # POST a single exposure for an enrolled (user, experiment, group). Deduped
      # per process (bounded set) so repeated assign() calls in one server don't
      # spam /collect. Fire-and-forget; no-op in test mode. This is how
      # assign_universe auto-logs — the browser's auto-exposure parity for SSR.
      def post_exposure(user, experiment, group)
        return if @offline
        u = user.transform_keys(&:to_s)
        uid = u["user_id"] || u["anonymous_id"]
        dedup_key = "#{uid}:#{experiment}:#{group}"
        @mutex.synchronize do
          return if @exposure_seen.key?(dedup_key)
          @exposure_seen.clear if @exposure_seen.size > 5000
          @exposure_seen[dedup_key] = true
        end

        payload = JSON.generate({
          events: [{
            type: "exposure",
            experiment: experiment.to_s,
            group: group,
            user_id: uid.to_s,
            ts: (Time.now.to_f * 1000).to_i,
          }],
        })

        Thread.new do
          post("/collect", payload)
        rescue => e
          Shipeasy::Logging.warn "[shipeasy] exposure send failed: #{e.message}"
        end
        nil
      end

      # Build the wire event and fire-and-forget POST it to /collect. No-op in
      # test mode (mirrors track). Spam-guarded. Never raises into caller code.
      def dispatch_see(built)
        return if @offline

        ev = See.build_event(
          built.problem,
          built.subject,
          built.outcome,
          strip_private(built.extras),
          sdk_version: Shipeasy::SDK::VERSION,
          env: @env,
          backtrace_cleaner: see_backtrace_cleaner,
        )
        return unless @see_limiter.should_send?(ev)

        payload = JSON.generate({ events: [ev] })
        Thread.new do
          post("/collect", payload)
        rescue => e
          Shipeasy::Logging.warn "[shipeasy] see() send failed: #{e.message}"
        end
      rescue => e
        Shipeasy::Logging.error "[shipeasy] see() failed: #{e.message}"
      end

      # The framework-provided backtrace cleaner used to strip gem/framework
      # frames from see() stacks, or nil to send the raw backtrace. Resolved
      # lazily (not memoized) because Rails installs its cleaner during boot,
      # which can finish after Shipeasy.configure runs. Today the only supported
      # cleaner is Rails' own `ActiveSupport::BacktraceCleaner` — we leverage it
      # rather than reimplementing the app-vs-gem frame rules ourselves. Returns
      # nil when disabled or when not running under Rails.
      def see_backtrace_cleaner
        return nil unless @clean_backtrace
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:backtrace_cleaner)

        cleaner = ::Rails.backtrace_cleaner
        return nil unless cleaner.respond_to?(:clean)

        ->(bt) { cleaner.clean(bt) }
      rescue StandardError
        # Rails present but the cleaner blew up while resolving: fall back to raw.
        nil
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
            Shipeasy::Logging.warn "[shipeasy] on_change listener raised: #{e.message}"
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

      # Serialize the server-identified user's traits for the SSR bootstrap tag's
      # data-user attribute: the request user minus `anonymous_id`, dropping
      # nil/empty values. Returns a stable-keyed JSON object, or nil when nothing
      # identified remains (a purely anonymous request) so data-user is omitted.
      # The browser SDK adopts this identity on first paint, killing the
      # anon->identified flip. See experiment-platform/18-identity-bucketing.md.
      def identity_attrs(user)
        return nil unless user.is_a?(Hash)

        traits = {}
        user.each do |k, v|
          next if k.to_s == "anonymous_id"
          next if v.nil?
          next if v.respond_to?(:empty?) && v.empty?

          traits[k.to_s] = v
        end
        return nil if traits.empty?

        JSON.generate(traits.sort.to_h)
      end

      def start_poll
        @timer = Thread.new do
          loop do
            sleep(@poll_interval)
            begin
              fetch_all
            rescue => e
              Shipeasy::Logging.error "[shipeasy] background poll failed: #{e.message}"
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
