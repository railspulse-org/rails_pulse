require "test_helper"

class RailsPulseTest < ActiveSupport::TestCase
  def setup
    ENV["TEST_TYPE"] = "functional"
    super
    @original_nav_items = RailsPulse.instance_variable_get(:@nav_items)
    @original_configuration = RailsPulse.configuration
    @original_logger = RailsPulse.instance_variable_get(:@logger)
    RailsPulse.instance_variable_set(:@nav_items, nil)
    # Always start with a fresh configuration so tests don't share mutable state
    RailsPulse.configuration = RailsPulse::Configuration.new
  end

  def teardown
    RailsPulse.instance_variable_set(:@nav_items, @original_nav_items)
    RailsPulse.configuration = @original_configuration
    RailsPulse.instance_variable_set(:@logger, @original_logger)
    super
  end

  # Version

  test "has a version number" do
    assert RailsPulse::VERSION
    assert_kind_of String, RailsPulse::VERSION
    assert_match(/\A\d+\.\d+\.\d+/, RailsPulse::VERSION)
  end

  # Pro Detection

  test "pro? returns false when RailsPulse::Pro is not defined" do
    refute_predicate RailsPulse, :pro?
  end

  # Nav Items

  test "nav_items returns empty array when nothing registered" do
    assert_empty RailsPulse.nav_items
  end

  test "register_nav_item adds item to nav_items" do
    RailsPulse.register_nav_item(label: "Reports", path_helper: :reports_path, icon: "chart")

    assert_equal 1, RailsPulse.nav_items.size
    item = RailsPulse.nav_items.first

    assert_equal "Reports", item[:label]
    assert_equal :reports_path, item[:path_helper]
    assert_equal "chart", item[:icon]
  end

  test "register_nav_item defaults position to 100" do
    RailsPulse.register_nav_item(label: "Reports", path_helper: :reports_path, icon: "chart")

    assert_equal 100, RailsPulse.nav_items.first[:position]
  end

  test "register_nav_item accepts custom position" do
    RailsPulse.register_nav_item(label: "Reports", path_helper: :reports_path, icon: "chart", position: 50)

    assert_equal 50, RailsPulse.nav_items.first[:position]
  end

  test "nav_items are sorted by position ascending" do
    RailsPulse.register_nav_item(label: "C", path_helper: :c_path, icon: "c", position: 30)
    RailsPulse.register_nav_item(label: "A", path_helper: :a_path, icon: "a", position: 10)
    RailsPulse.register_nav_item(label: "B", path_helper: :b_path, icon: "b", position: 20)

    labels = RailsPulse.nav_items.map { |i| i[:label] }

    assert_equal [ "A", "B", "C" ], labels
  end

  test "register_nav_item re-sorts after each registration" do
    RailsPulse.register_nav_item(label: "Late", path_helper: :late_path, icon: "x", position: 200)
    RailsPulse.register_nav_item(label: "Early", path_helper: :early_path, icon: "y", position: 1)

    assert_equal "Early", RailsPulse.nav_items.first[:label]
    assert_equal "Late", RailsPulse.nav_items.last[:label]
  end

  test "nav_items returns array with all registered items" do
    3.times { |i| RailsPulse.register_nav_item(label: "Item #{i}", path_helper: :"item_#{i}_path", icon: "icon", position: i) }

    assert_equal 3, RailsPulse.nav_items.size
  end

  # Configure

  test "configure yields configuration object" do
    yielded = nil
    RailsPulse.configure { |c| yielded = c }

    assert_kind_of RailsPulse::Configuration, yielded
  end

  test "configure sets configuration values" do
    RailsPulse.configure do |c|
      c.track_jobs = true
    end

    assert RailsPulse.configuration.track_jobs
  end

  test "configure reuses existing configuration on subsequent calls" do
    RailsPulse.configure { |c| c.track_jobs = true }
    first = RailsPulse.configuration
    RailsPulse.configure { |c| c.track_assets = true }

    assert_same first, RailsPulse.configuration
  end

  test "configure does not raise with valid configuration" do
    assert_nothing_raised { RailsPulse.configure { |_c| } }
  end

  test "configure raises ArgumentError on invalid configuration" do
    assert_raises(ArgumentError) do
      RailsPulse.configure do |c|
        c.full_retention_period = "not-a-duration"
      end
    end
  end

  test "configure raises ArgumentError when tags is not an array" do
    assert_raises(ArgumentError) do
      RailsPulse.configure { |c| c.tags = "not-an-array" }
    end
  end

  # Logger

  test "logger returns tagged logging instance" do
    RailsPulse.instance_variable_set(:@logger, nil)
    logger = RailsPulse.logger

    assert_respond_to logger, :info
    assert_respond_to logger, :error
    assert_respond_to logger, :warn
  end

  test "logger is memoized" do
    RailsPulse.instance_variable_set(:@logger, nil)

    assert_same RailsPulse.logger, RailsPulse.logger
  end

  test "logger delivers messages to the configured logger instead of Rails.logger" do
    original = Rails.logger
    rails_output = StringIO.new
    custom_output = StringIO.new
    Rails.logger = Logger.new(rails_output)
    RailsPulse.instance_variable_set(:@logger, nil)
    RailsPulse.configuration.logger = Logger.new(custom_output)

    RailsPulse.logger.warn("configured logger probe")

    assert_includes custom_output.string, "configured logger probe"
    assert_not_includes rails_output.string, "configured logger probe"
  ensure
    Rails.logger = original
    RailsPulse.instance_variable_set(:@logger, nil)
  end

  test "logger honors a logger configured after the default logger was already used" do
    original = Rails.logger
    rails_output = StringIO.new
    custom_output = StringIO.new
    Rails.logger = Logger.new(rails_output)
    RailsPulse.instance_variable_set(:@logger, nil)

    RailsPulse.logger.warn("before configuration")

    assert_includes rails_output.string, "before configuration"

    RailsPulse.configuration.logger = Logger.new(custom_output)
    RailsPulse.logger.warn("after configuration")

    assert_includes custom_output.string, "after configuration"
    assert_not_includes rails_output.string, "after configuration"
  ensure
    Rails.logger = original
    RailsPulse.instance_variable_set(:@logger, nil)
  end

  # connects_to

  test "connects_to returns nil when configuration has no connects_to" do
    RailsPulse.configuration = RailsPulse::Configuration.new

    assert_nil RailsPulse.connects_to
  end

  test "connects_to delegates to configuration" do
    RailsPulse.configuration = RailsPulse::Configuration.new
    RailsPulse.configuration.connects_to = { database: { writing: :primary } }

    assert_equal({ database: { writing: :primary } }, RailsPulse.connects_to)
  end

  test "connects_to returns nil when configuration is nil" do
    RailsPulse.configuration = nil

    assert_nil RailsPulse.connects_to
  end

  # clear_metric_cache!

  test "clear_metric_cache! removes matching cache entries" do
    Rails.cache.write("rails_pulse_metric_foo", "bar")
    Rails.cache.write("rails_pulse_metric_baz", "qux")
    Rails.cache.write("other_key", "untouched")

    RailsPulse.clear_metric_cache!

    assert_nil Rails.cache.read("rails_pulse_metric_foo")
    assert_nil Rails.cache.read("rails_pulse_metric_baz")
    assert_equal "untouched", Rails.cache.read("other_key")
  ensure
    Rails.cache.delete("other_key")
  end

  # warm_metric_cache!

  test "warm_metric_cache! does not raise" do
    assert_nothing_raised { RailsPulse.warm_metric_cache! }
  end

  # Configuration default

  test "configuration is initialized by default" do
    assert_kind_of RailsPulse::Configuration, RailsPulse.configuration
  end

  test "logger falls back to stdout when Rails.logger is nil" do
    original = Rails.logger
    Rails.logger = nil
    RailsPulse.instance_variable_set(:@logger, nil)

    logger = RailsPulse.logger

    assert_respond_to logger, :warn
    assert_respond_to logger, :info
  ensure
    Rails.logger = original
    RailsPulse.instance_variable_set(:@logger, nil)
  end

  test "logger is not memoized when falling back so real logger is picked up later" do
    original = Rails.logger
    Rails.logger = nil
    RailsPulse.instance_variable_set(:@logger, nil)

    # First call with nil Rails.logger returns a fallback logger
    fallback_logger = RailsPulse.logger

    # Simulate Rails finishing boot and providing a real logger
    Rails.logger = original

    # Next call should pick up the real logger, not the fallback
    real_logger = RailsPulse.logger

    assert_respond_to real_logger, :tagged
    assert_respond_to real_logger, :formatter
    assert_not_equal fallback_logger, real_logger
  ensure
    Rails.logger = original
    RailsPulse.instance_variable_set(:@logger, nil)
  end
end
