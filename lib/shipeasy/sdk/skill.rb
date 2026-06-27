# frozen_string_literal: true

require "fileutils"

module Shipeasy
  module SDK
    # `shipeasy-skill` — install the bundled Shipeasy agent skill into a project.
    #
    # RubyGems has no safe post-install hook (gems don't run code on install;
    # installers run non-interactively), so installing the skill is an explicit,
    # opt-in command:
    #
    #     shipeasy-skill install                 # → .claude/skills/shipeasy-ruby/SKILL.md
    #     shipeasy-skill install --dir path/     # custom destination (file or dir)
    #     shipeasy-skill install --force         # overwrite an existing file
    #     shipeasy-skill print                   # write the skill to stdout
    #
    # The skill (`docs/skill/SKILL.md`) is shipped inside the gem, so this reads
    # it with no network — relative to this file, which works both from an
    # installed gem and a source checkout.
    module Skill
      DEFAULT_DEST = ".claude/skills/shipeasy-ruby/SKILL.md"

      # The bundled SKILL.md, read from docs/skill/SKILL.md (a sibling of lib/ in
      # both the installed gem and a source checkout).
      def self.skill_text
        path = File.expand_path("../../../docs/skill/SKILL.md", __dir__)
        File.read(path)
      end

      # Copy the skill to +dest+ (a file, or a directory it's written into).
      def self.install(dest, force: false)
        dest = File.join(dest, "SKILL.md") if File.directory?(dest) || File.extname(dest).empty?
        if File.exist?(dest) && !force
          warn "shipeasy-skill: refusing to overwrite #{dest} — pass --force"
          return 1
        end
        FileUtils.mkdir_p(File.dirname(dest))
        File.write(dest, skill_text)
        puts "shipeasy-skill: installed the Shipeasy agent skill → #{dest}"
        0
      end

      def self.main(argv)
        cmd = argv.shift
        case cmd
        when "install"
          dest  = DEFAULT_DEST
          force = false
          while (arg = argv.shift)
            case arg
            when "--dir" then dest = argv.shift
            when "--force" then force = true
            else
              warn "shipeasy-skill: unknown argument #{arg}"
              return 1
            end
          end
          install(dest, force: force)
        when "print"
          puts skill_text
          0
        else
          puts <<~USAGE
            shipeasy-skill — install the Shipeasy Ruby agent skill into your project.

            Usage:
              shipeasy-skill install [--dir PATH] [--force]   copy SKILL.md (default: #{DEFAULT_DEST})
              shipeasy-skill print                            print the skill to stdout
          USAGE
          0
        end
      end
    end
  end
end
