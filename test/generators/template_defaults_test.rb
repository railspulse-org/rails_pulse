require "test_helper"

module RailsPulse
  # RailsPulse::Configuration#initialize and the install template are two
  # independent sources of defaults, and ConfigUpdater appends template
  # settings to upgraders' initializers, so drift between them reaches every
  # install. Evaluating the template into a fresh Configuration and comparing
  # it attribute by attribute catches a change made in one place only.
  class TemplateDefaultsTest < ActiveSupport::TestCase
    TEMPLATE = File.expand_path("../../lib/generators/rails_pulse/templates/rails_pulse.rb", __dir__)

    # Keys the template deliberately sets differently for new installs. Each
    # entry must actually differ, or it is removed from this list.
    INTENDED_DIFFERENCES = {
      track_exceptions: "new installs opt in; the default stays off so a 0.3.x initializer without the key does not start capturing on upgrade",
      async: "the template turns async off under Rails.env.test?, and this suite runs in test"
    }.freeze

    setup do
      @defaults = RailsPulse::Configuration.new
      @from_template = load_template_into_fresh_configuration
    end

    # Structure Tests

    test "every configuration attribute has the same value in Configuration.new and the install template" do
      drifted = attribute_names.reject { |name| INTENDED_DIFFERENCES.key?(name) }.filter_map do |name|
        default = @defaults.instance_variable_get(:"@#{name}")
        templated = @from_template.instance_variable_get(:"@#{name}")
        next if default == templated

        "#{name}: Configuration.new has #{default.inspect}, the install template sets #{templated.inspect}"
      end

      assert_empty drifted, "Defaults have drifted between lib/rails_pulse/configuration.rb and the install template:\n  #{drifted.join("\n  ")}"
    end

    test "the template validates as a complete configuration" do
      assert_nothing_raised { @from_template.validate_configuration! }
    end

    # Edge Cases

    test "every intended difference still differs, so the allow-list cannot go stale" do
      INTENDED_DIFFERENCES.each_key do |name|
        assert_not_equal @defaults.instance_variable_get(:"@#{name}"), @from_template.instance_variable_get(:"@#{name}"),
                         "#{name} no longer differs between Configuration.new and the template; remove it from INTENDED_DIFFERENCES"
      end
    end

    private

    def attribute_names
      @defaults.instance_variables.map { |ivar| ivar.to_s.delete_prefix("@").to_sym }
    end

    # The template is a plain initializer that calls RailsPulse.configure; hand
    # it a fresh Configuration instead of the global one.
    def load_template_into_fresh_configuration
      config = RailsPulse::Configuration.new
      RailsPulse.stubs(:configure).yields(config)
      load TEMPLATE
      config
    ensure
      RailsPulse.unstub(:configure)
    end
  end
end
