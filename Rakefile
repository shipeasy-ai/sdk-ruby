require "bundler/gem_tasks"

begin
  require "rspec/core/rake_task"
  RSpec::Core::RakeTask.new(:spec)
  task default: :spec
rescue LoadError
  # rspec not installed (e.g. production install) — leave default empty.
end

desc "Regenerate README.md from docs/ (single source of truth)"
task :readme do
  ruby File.expand_path("scripts/gen_readme.rb", __dir__)
end
