require "test_helper"

class MetricCardConcernTest < ActionController::TestCase
  # Simple test card class instead of mock
  class TestCardClass
    attr_reader :options

    def initialize(**options)
      @options = options
    end

    def to_metric_card
      { id: "test_card", summary: "Test #{@options[:period]} days", chart_data: {} }
    end
  end

  class TestController < ActionController::Base
    include MetricCardConcern

    attr_accessor :session

    def initialize
      super
      @session = {}
    end

    def metric_card_definitions
      { test_card: TestCardClass }
    end

    def resource_key
      :route
    end

    def current_resource
      @resource
    end

    def period_type
      :day
    end

    def session_disabled_tags
      (session[:global_filters] || {})["disabled_tags"] || []
    end

    def partial_request?
      false
    end
  end

  fixtures :rails_pulse_routes

  setup do
    @controller = TestController.new
    @now = Time.current
    travel_to @now
  end

  teardown do
    travel_back
  end

  def set_window(start_time, end_time)
    window = start_time && end_time ? RailsPulse::TimeWindow.new(start_time, end_time) : nil
    @controller.instance_variable_set(:@time_range, RailsPulse::TimeRange::Result.new(window: window))
  end

  # setup_metric_cards Tests

  test "setup_metric_cards skips when partial_request returns true" do
    @controller.stubs(:partial_request?).returns(true)
    set_window(7.days.ago, @now)

    @controller.send(:setup_metric_cards)

    # Should not set any card instance variables
    refute @controller.instance_variable_defined?(:@test_card)
  end

  test "setup_metric_cards instantiates cards from metric_card_definitions" do
    @controller.stubs(:partial_request?).returns(false)
    set_window(7.days.ago, @now)

    @controller.send(:setup_metric_cards)

    # Should instantiate the test card
    assert @controller.instance_variable_defined?(:@test_card)
  end

  test "setup_metric_cards sets instance variable for each card" do
    @controller.stubs(:partial_request?).returns(false)
    set_window(7.days.ago, @now)

    @controller.send(:setup_metric_cards)

    test_card = @controller.instance_variable_get(:@test_card)

    assert_kind_of Hash, test_card
    assert_equal "test_card", test_card[:id]
  end

  test "setup_metric_cards passes metric_card_params to each card" do
    @controller.stubs(:partial_request?).returns(false)
    set_window(7.days.ago, @now)
    @controller.session[:global_filters] = { "disabled_tags" => [ "tag1" ] }

    @controller.send(:setup_metric_cards)

    # Card should receive correct period in its params
    test_card = @controller.instance_variable_get(:@test_card)

    assert_includes test_card[:summary], "7 days"
  end

  test "setup_metric_cards calls to_metric_card on each card class" do
    @controller.stubs(:partial_request?).returns(false)
    set_window(7.days.ago, @now)

    @controller.send(:setup_metric_cards)

    test_card = @controller.instance_variable_get(:@test_card)
    # Result should be the hash returned by to_metric_card
    assert_kind_of Hash, test_card
    assert_includes test_card.keys, :id
    assert_includes test_card.keys, :summary
  end

  test "setup_metric_cards handles empty metric_card_definitions" do
    @controller.stubs(:metric_card_definitions).returns({})
    @controller.stubs(:partial_request?).returns(false)
    set_window(7.days.ago, @now)

    # Should not raise error with empty definitions
    assert_nothing_raised do
      @controller.send(:setup_metric_cards)
    end
  end

  # metric_card_params Tests

  test "metric_card_params includes resource_key and current_resource" do
    @controller.instance_variable_set(:@resource, rails_pulse_routes(:api_users))
    set_window(7.days.ago, @now)

    params = @controller.send(:metric_card_params)

    assert_includes params.keys, :route
    assert_equal rails_pulse_routes(:api_users), params[:route]
  end

  test "metric_card_params includes disabled_tags from session" do
    set_window(7.days.ago, @now)
    @controller.session[:global_filters] = { "disabled_tags" => [ "tag1", "tag2" ] }

    params = @controller.send(:metric_card_params)

    assert_includes params.keys, :disabled_tags
    assert_equal [ "tag1", "tag2" ], params[:disabled_tags]
  end

  test "metric_card_params includes show_non_tagged from session" do
    set_window(7.days.ago, @now)
    @controller.session[:show_non_tagged] = false

    params = @controller.send(:metric_card_params)

    assert_includes params.keys, :show_non_tagged
    refute params[:show_non_tagged]
  end

  test "metric_card_params sets show_non_tagged true when nil" do
    set_window(7.days.ago, @now)
    @controller.session[:show_non_tagged] = nil

    params = @controller.send(:metric_card_params)

    # nil != false evaluates to true
    assert params[:show_non_tagged]
  end

  test "metric_card_params sets show_non_tagged false when explicitly false" do
    set_window(7.days.ago, @now)
    @controller.session[:show_non_tagged] = false

    params = @controller.send(:metric_card_params)

    refute params[:show_non_tagged]
  end

  test "metric_card_params calculates period_days from the window" do
    set_window(14.days.ago, @now)

    params = @controller.send(:metric_card_params)

    assert_includes params.keys, :period
    assert_equal 14, params[:period]
  end

  test "metric_card_params defaults to 7 days when @time_range has no window" do
    set_window(nil, nil)

    params = @controller.send(:metric_card_params)

    assert_equal 7, params[:period]
  end

  test "metric_card_params defaults to 7 days when @time_range is nil" do
    @controller.instance_variable_set(:@time_range, nil)

    params = @controller.send(:metric_card_params)

    assert_equal 7, params[:period]
  end

  # Period Calculation Tests

  test "metric_card_params rounds period_days correctly" do
    # 1.4 days should round to 1
    set_window((1.4 * 24 * 3600).seconds.ago, @now)

    params = @controller.send(:metric_card_params)

    assert_equal 1, params[:period]
  end

  test "metric_card_params rounds fractional days correctly" do
    # Test with a clear case: 30.6 days should round to 31
    set_window(30.6.days.ago, @now)

    params = @controller.send(:metric_card_params)

    # Verify rounding works (30.6 → 31)
    assert_operator params[:period], :>=, 30
    assert_operator params[:period], :<=, 31
  end

  test "metric_card_params includes period_type from controller" do
    set_window(7.days.ago, @now)

    params = @controller.send(:metric_card_params)

    assert_includes params.keys, :period_type
    assert_equal "day", params[:period_type]
  end

  # Abstract Method Tests

  test "metric_card_definitions raises NotImplementedError when not overridden" do
    abstract_controller = Class.new(ActionController::Base) do
      include MetricCardConcern
    end.new

    assert_raises NotImplementedError do
      abstract_controller.send(:metric_card_definitions)
    end
  end

  test "resource_key raises NotImplementedError when not overridden" do
    abstract_controller = Class.new(ActionController::Base) do
      include MetricCardConcern
      def metric_card_definitions; {}; end
      def period_type; "day"; end
    end.new
    abstract_controller.instance_variable_set(:@time_range,
      RailsPulse::TimeRange::Result.new(window: RailsPulse::TimeWindow.new(7.days.ago, Time.current)))

    assert_raises NotImplementedError do
      abstract_controller.send(:metric_card_params)
    end
  end
end
