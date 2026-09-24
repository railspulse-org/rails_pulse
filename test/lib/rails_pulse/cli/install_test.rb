require "test_helper"
require "rails_pulse/cli/install"
require "tmpdir"

module RailsPulse
  module CLI
    class InstallTest < ActiveSupport::TestCase
      include ApiClientTestHelpers

      def setup
        @tmpdir = Dir.mktmpdir
        @original_home = ENV["HOME"]
        ENV["HOME"] = @tmpdir
      end

      def teardown
        ENV["HOME"] = @original_home
        FileUtils.rm_rf(@tmpdir)
      end

      def run_install(integration = nil, options = {})
        defaults = { "list" => false }
        cmd = Install.new([], defaults.merge(options.transform_keys(&:to_s)))
        capture_io { cmd.perform(integration) }
      end

      # --- --list flag ---

      test "--list outputs all available integrations" do
        out, _err = run_install(nil, list: true)

        assert_includes out, "claude"
        assert_includes out, "agents"
      end

      # --- claude integration ---

      test "install claude writes the skill to ~/.claude/skills/rails-pulse/SKILL.md" do
        run_install("claude")

        dest = File.join(@tmpdir, ".claude", "skills", "rails-pulse", "SKILL.md")

        assert_path_exists dest, "Expected #{dest} to exist"
      end

      test "the installed skill carries Claude Code front matter" do
        run_install("claude")
        skill = File.read(File.join(@tmpdir, ".claude", "skills", "rails-pulse", "SKILL.md"))

        assert_match(/\A---\nname: rails-pulse\ndescription: .+\n---\n/, skill)
      end

      test "install claude confirms destination in output" do
        out, _err = run_install("claude")

        assert_includes out, "skills/rails-pulse/SKILL.md"
      end

      # --- agents integration ---

      test "install agents copies agents.md to current directory" do
        Dir.chdir(@tmpdir) do
          run_install("agents")

          assert_path_exists File.join(@tmpdir, "agents.md"), "Expected agents.md to exist in #{@tmpdir}"
        end
      end

      test "install agents confirms destination in output" do
        Dir.chdir(@tmpdir) do
          out, _err = run_install("agents")

          assert_includes out, "agents.md"
        end
      end

      # --- unknown integration ---

      test "unknown integration shows usage hint" do
        out, _err = run_install("unknown")

        assert_includes out, "Usage:"
      end

      test "no integration shows usage hint" do
        out, _err = run_install(nil)

        assert_includes out, "Usage:"
      end
    end
  end
end
