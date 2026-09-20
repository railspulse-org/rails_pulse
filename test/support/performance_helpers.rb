module PerformanceHelpers
  # Pre-calculated performance data to avoid expensive operations in tests
  SAMPLE_DURATIONS = [ 50, 75, 100, 150, 200, 300, 500, 750, 1000, 1500 ].freeze
  SAMPLE_STATUSES = [ 200, 201, 302, 404, 422, 500 ].freeze
  SAMPLE_PATHS = [ "/api/users", "/api/posts", "/admin/dashboard", "/api/search" ].freeze

  # Create minimal performance data for testing
  def create_sample_requests(count: 5)
    route = rails_pulse_routes(:api_users)
    base_time = 1.hour.ago

    count.times do |i|
      RailsPulse::Request.create!(
        route: route,
        occurred_at: base_time + (i * 10).minutes,
        duration: SAMPLE_DURATIONS.sample,
        status: SAMPLE_STATUSES.sample,
        is_error: [ true, false ].sample,
        request_uuid: SecureRandom.uuid
      )
    end
  end

  # Stub expensive chart calculations
  def stub_chart_calculations
    RailsPulse::Dashboard::Charts::AverageResponseTime.stubs(:call).returns(
      { labels: [ "12:00", "13:00", "14:00" ], data: [ 100, 120, 95 ] }
    )

    RailsPulse::Dashboard::Charts::P95ResponseTime.stubs(:call).returns(
      { labels: [ "12:00", "13:00", "14:00" ], data: [ 250, 300, 275 ] }
    )
  end

  # Stub time-based operations for consistent test results
  def stub_time_operations(fixed_time = Time.current)
    return unless defined?(Mocha)
    Time.stubs(:current).returns(fixed_time)
    Time.stubs(:now).returns(fixed_time)
    DateTime.stubs(:current).returns(fixed_time)
  end

  # Pre-calculated aggregation results to avoid database queries
  def mock_aggregation_results
    {
      average_response_time: 125.5,
      p95_response_time: 300.0,
      error_rate: 2.5,
      request_count: 1250
    }
  end

  # Fast time-series data generation using Timecop
  def generate_time_series_data(start_time, end_time, interval: 1.hour)
    data = []
    current_time = start_time

    while current_time <= end_time
      Timecop.freeze(current_time) do
        data << {
          timestamp: current_time,
          value: block_given? ? yield(current_time) : rand(50..200)
        }
      end
      current_time += interval
    end

    data
  end

  # Threshold testing patterns (merged from performance_test_helpers)
  def assert_performance_threshold(actual_duration, expected_threshold, comparison: :under)
    case comparison
    when :under

      assert_operator actual_duration, :<, expected_threshold, "Expected duration #{actual_duration}ms to be under threshold #{expected_threshold}ms"
    when :over

      assert_operator actual_duration, :>, expected_threshold, "Expected duration #{actual_duration}ms to be over threshold #{expected_threshold}ms"
    when :at

      assert_equal expected_threshold, actual_duration,
        "Expected duration #{actual_duration}ms to equal threshold #{expected_threshold}ms"
    end
  end

  def assert_fast_request(request, threshold: 100)
    assert_performance_threshold(request.duration, threshold, comparison: :under)
  end

  def assert_slow_request(request, threshold: 500)
    assert_performance_threshold(request.duration, threshold, comparison: :over)
  end

  def assert_critical_request(request, threshold: 1000)
    assert_performance_threshold(request.duration, threshold, comparison: :over)
  end

  # Performance scenario generators
  def create_fast_scenario(count: 10)
    create_list(:request, count, :fast)
  end

  def create_slow_scenario(count: 5)
    create_list(:request, count, :slow)
  end

  def create_critical_scenario(count: 2)
    create_list(:request, count, :critical)
  end

  def create_mixed_performance_scenario(total: 20)
    fast_count = (total * 0.7).to_i
    slow_count = (total * 0.2).to_i
    critical_count = total - fast_count - slow_count

    {
      fast: create_fast_scenario(count: fast_count),
      slow: create_slow_scenario(count: slow_count),
      critical: create_critical_scenario(count: critical_count)
    }
  end

  # Time-based test data creation
  def create_requests_over_time(
    duration: 1.day,
    interval: 1.hour,
    starting_at: 1.day.ago,
    request_traits: [ :realistic ]
  )
    requests = []
    current_time = starting_at
    end_time = starting_at + duration

    while current_time < end_time
      traits = request_traits.dup
      traits << { occurred_at: current_time }
      requests << create(:request, *traits)
      current_time += interval
    end

    requests
  end

  # Metrics calculation test helpers
  def assert_average_duration(requests, expected_average, tolerance: 5)
    actual_average = requests.sum(&:duration) / requests.count.to_f

    assert_in_delta expected_average, actual_average, tolerance,
      "Expected average duration to be around #{expected_average}ms, got #{actual_average}ms"
  end

  def assert_percentile_duration(requests, percentile: 95, expected_duration: nil, max_duration: nil)
    durations = requests.map(&:duration).sort
    index = ((percentile / 100.0) * durations.length).ceil - 1
    actual_percentile = durations[index]

    if expected_duration
      assert_equal expected_duration, actual_percentile,
        "Expected #{percentile}th percentile to be #{expected_duration}ms, got #{actual_percentile}ms"
    end

    if max_duration
      assert_operator actual_percentile, :<=, max_duration, "Expected #{percentile}th percentile (#{actual_percentile}ms) to be under #{max_duration}ms"
    end

    actual_percentile
  end

  def assert_error_rate(requests, expected_rate, tolerance: 0.01)
    error_count = requests.count(&:is_error)
    actual_rate = error_count / requests.count.to_f

    assert_in_delta expected_rate, actual_rate, tolerance,
      "Expected error rate to be around #{expected_rate}, got #{actual_rate}"
  end

  # Stub helpers (merged from stub_helpers.rb)
  def stub_rails_pulse_middleware
    return unless defined?(Mocha)
    RailsPulse::Middleware::RequestCollector.stubs(:new).returns(mock_middleware)
  end

  def stub_expensive_queries
    return unless defined?(Mocha)
    RailsPulse::Request.stubs(:ransack).returns(mock_ransack_result)
  end

  def stub_all_external_dependencies
    stub_expensive_queries
    stub_chart_calculations
  end

  private

  def mock_middleware
    middleware = mock("middleware")
    middleware.stubs(:call).returns([ 200, {}, [ "OK" ] ])
    middleware
  end

  def mock_grouped_data
    {
      Time.current => 100,
      1.hour.ago => 120,
      2.hours.ago => 95
    }
  end

  def mock_ransack_result
    result = mock("ransack_result")
    result.stubs(:result).returns(RailsPulse::Request.none)
    result
  end
end
