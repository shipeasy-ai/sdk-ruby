# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "rails/generators"
require "generators/shipeasy/install/install_generator"

# Drive the generator directly (no ammeter / rspec-rails) — it only needs
# railties' Rails::Generators::Base. We invoke it against a throwaway
# destination and assert on the files it writes.
RSpec.describe Shipeasy::Generators::InstallGenerator do
  dest        = File.expand_path("../tmp/generator", __dir__)
  layout_rel  = "app/views/layouts/application.html.erb"
  layout      = File.join(dest, layout_rel)
  initializer = File.join(dest, "config/initializers/shipeasy.rb")

  def generate(args, dest)
    out = StringIO.new
    orig = $stdout
    $stdout = out
    described_class.start(args, destination_root: dest)
  ensure
    $stdout = orig
  end

  before do
    FileUtils.rm_rf(dest)
    FileUtils.mkdir_p(File.dirname(layout))
    File.write(layout, <<~ERB)
      <!DOCTYPE html>
      <html>
        <head>
          <title>Dummy</title>
        </head>
        <body><%= yield %></body>
      </html>
    ERB
  end

  after(:all) { FileUtils.rm_rf(File.expand_path("../tmp", __dir__)) }

  describe "default install" do
    before { generate([], dest) }

    it "writes the initializer with the server key + background poll" do
      content = File.read(initializer)
      expect(content).to include("Shipeasy.configure")
      expect(content).to include('ENV.fetch("SHIPEASY_SERVER_KEY"')
      expect(content).to include("c.poll = true")
    end

    it "leaves i18n out of the initializer" do
      expect(File.read(initializer)).not_to include("public_key")
    end

    it "does not touch the application layout" do
      expect(File.read(layout)).not_to include("i18n_head_tags")
    end
  end

  describe "with --i18n" do
    before { generate(%w[--i18n], dest) }

    it "enables the public client key + profile in the initializer" do
      content = File.read(initializer)
      expect(content).to include('ENV.fetch("SHIPEASY_CLIENT_KEY"')
      expect(content).to include("c.profile")
    end

    it "injects i18n_head_tags before the closing </head>" do
      content = File.read(layout)
      expect(content).to include("<%= i18n_head_tags %>")
      expect(content.index("i18n_head_tags")).to be < content.index("</head>")
    end

    it "is idempotent on the layout (second run with --force adds no duplicate)" do
      generate(%w[--i18n --force], dest)
      expect(File.read(layout).scan("i18n_head_tags").length).to eq(1)
    end
  end

  describe "with --no-poll" do
    before { generate(%w[--no-poll], dest) }

    it "uses a one-shot fetch" do
      expect(File.read(initializer)).to include("c.poll = false")
    end
  end

  describe "when the application layout is missing" do
    before do
      FileUtils.rm_f(layout)
      generate(%w[--i18n], dest)
    end

    it "still writes the initializer and does not crash" do
      expect(File.read(initializer)).to include('ENV.fetch("SHIPEASY_CLIENT_KEY"')
      expect(File.exist?(layout)).to be(false)
    end
  end
end
