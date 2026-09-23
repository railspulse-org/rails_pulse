require "test_helper"

module RailsPulse
  class ExceptionCaptureServiceTest < ActiveSupport::TestCase
    fixtures :rails_pulse_exception_groups, :rails_pulse_exception_occurrences, :rails_pulse_deployments

    def setup
      ENV["TEST_TYPE"] = "functional"
      super
      RailsPulse::Current.skip_recording_rails_pulse_activity = false
    end

    def teardown
      ExceptionCaptureService.reset_deploy_sha_cache!
      RailsPulse::Current.reset
      super
    end

    def make_exception(klass = RuntimeError, message = "something went wrong")
      begin
        raise klass, message
      rescue => e
        e
      end
    end

    # Capture — group creation

    test "creates a new exception group on first capture" do
      exception = make_exception(ArgumentError, "bad arg")

      assert_difference -> { ExceptionGroup.count }, 1 do
        ExceptionCaptureService.capture(exception)
      end
    end

    test "sets exception_class on the group" do
      exception = make_exception(ArgumentError, "bad arg")
      ExceptionCaptureService.capture(exception)

      group = ExceptionGroup.order(:created_at).last

      assert_equal "ArgumentError", group.exception_class
    end

    test "sets first_seen_at and last_seen_at" do
      exception = make_exception(ArgumentError, "bad arg")
      ExceptionCaptureService.capture(exception)

      group = ExceptionGroup.order(:created_at).last

      assert_not_nil group.first_seen_at
      assert_not_nil group.last_seen_at
    end

    test "increments occurrence_count on repeated captures of the same exception" do
      exception = make_exception(ArgumentError, "bad arg")

      ExceptionCaptureService.capture(exception)
      group = ExceptionGroup.order(:created_at).last
      first_count = group.occurrence_count

      ExceptionCaptureService.capture(exception)

      assert_equal first_count + 1, group.reload.occurrence_count
    end

    test "does not create a duplicate group for the same fingerprint" do
      exception = make_exception(ArgumentError, "bad arg")

      ExceptionCaptureService.capture(exception)
      assert_no_difference -> { ExceptionGroup.count } do
        ExceptionCaptureService.capture(exception)
      end
    end

    # Capture — occurrence creation

    test "creates an occurrence on each capture" do
      exception = make_exception(ArgumentError, "bad arg")

      assert_difference -> { ExceptionOccurrence.count }, 1 do
        ExceptionCaptureService.capture(exception)
      end
    end

    test "stores request context on the occurrence" do
      exception = make_exception(RuntimeError, "oops")
      ExceptionCaptureService.capture(exception, request_url: "/posts/1", request_method: "GET")

      occurrence = ExceptionOccurrence.order(:created_at).last

      assert_equal "/posts/1", occurrence.request_url
      assert_equal "GET", occurrence.request_method
    end

    test "stores environment on the occurrence" do
      exception = make_exception(RuntimeError, "oops")
      ExceptionCaptureService.capture(exception, environment: "staging")

      occurrence = ExceptionOccurrence.order(:created_at).last

      assert_equal "staging", occurrence.environment
    end

    test "stores structured backtrace frames" do
      exception = make_exception(RuntimeError, "oops")
      ExceptionCaptureService.capture(exception)

      occurrence = ExceptionOccurrence.order(:created_at).last

      assert_kind_of Array, occurrence.backtrace
      # Should have at least one frame from this test file
      assert_operator occurrence.backtrace.length, :>, 0
      first_frame = occurrence.backtrace.first

      assert first_frame.key?("file")
      assert first_frame.key?("line")
      assert first_frame.key?("method")
    end

    # Edge cases

    test "is a no-op when skip_recording flag is set" do
      RailsPulse::Current.skip_recording_rails_pulse_activity = true
      exception = make_exception(RuntimeError, "oops")

      assert_no_difference -> { ExceptionGroup.count } do
        ExceptionCaptureService.capture(exception)
      end
    end

    test "handles nil backtrace gracefully" do
      exception = make_exception(RuntimeError, "no trace")
      exception.stubs(:backtrace).returns(nil)

      assert_nothing_raised do
        ExceptionCaptureService.capture(exception)
      end
    end

    test "truncates very long messages to 500 characters" do
      long_message = "x" * 600
      exception = make_exception(RuntimeError, long_message)
      ExceptionCaptureService.capture(exception)

      occurrence = ExceptionOccurrence.order(:created_at).last

      assert_operator occurrence.message.length, :<=, 500
    end

    test "groups exceptions with no app-code frames under unknown location" do
      exception = make_exception(RuntimeError, "gem error")
      fake_backtrace = [ "/usr/local/bundle/gems/activesupport-7.0.0/lib/foo.rb:1:in 'bar'" ]
      exception.stubs(:backtrace).returns(fake_backtrace)

      assert_difference -> { ExceptionGroup.count }, 1 do
        ExceptionCaptureService.capture(exception)
      end

      group = ExceptionGroup.order(:created_at).last

      assert_not_nil group.fingerprint
    end

    test "returns nil and logs on unexpected error without raising" do
      exception = make_exception(RuntimeError, "oops")
      ExceptionGroup.stubs(:find_by!).raises(StandardError, "db exploded")

      assert_nothing_raised do
        result = ExceptionCaptureService.capture(exception)

        assert_nil result
      end
    end

    test "parsed method names do not include a trailing single quote (old-style backtick-open format)" do
      exception = make_exception(RuntimeError, "oops")
      old_style = [ "/app/models/user.rb:10:in `find'" ]
      exception.stubs(:backtrace).returns(old_style)

      ExceptionCaptureService.capture(exception)
      occurrence = ExceptionOccurrence.order(:created_at).last

      assert_equal 1, occurrence.backtrace.length
      assert_equal "find", occurrence.backtrace.first["method"],
        "method name should not include a trailing quote"
    end

    test "parsed method names do not include a trailing single quote (new-style single-quote format)" do
      exception = make_exception(RuntimeError, "oops")
      new_style = [ "/app/models/user.rb:10:in 'find'" ]
      exception.stubs(:backtrace).returns(new_style)

      ExceptionCaptureService.capture(exception)
      occurrence = ExceptionOccurrence.order(:created_at).last

      assert_equal 1, occurrence.backtrace.length
      assert_equal "find", occurrence.backtrace.first["method"],
        "method name should not include a trailing quote"
    end

    test "parsed backtrace correctly extracts file and line number" do
      exception = make_exception(RuntimeError, "oops")
      exception.stubs(:backtrace).returns([ "/app/controllers/posts_controller.rb:42:in 'create'" ])

      ExceptionCaptureService.capture(exception)
      frame = ExceptionOccurrence.order(:created_at).last.backtrace.first

      assert_equal "/app/controllers/posts_controller.rb", frame["file"]
      assert_equal 42, frame["line"]
      assert_equal "create", frame["method"]
    end

    test "exceptions originating from /lib/ code get distinct fingerprints by location" do
      lib_frame_a = [ "/lib/services/payment_service.rb:15:in 'charge'" ]
      lib_frame_b = [ "/lib/services/email_service.rb:8:in 'deliver'" ]

      exception_a = make_exception(RuntimeError, "payment failed")
      exception_b = make_exception(RuntimeError, "email failed")
      exception_a.stubs(:backtrace).returns(lib_frame_a)
      exception_b.stubs(:backtrace).returns(lib_frame_b)

      ExceptionCaptureService.capture(exception_a)
      ExceptionCaptureService.capture(exception_b)

      groups = ExceptionGroup.order(:created_at).last(2)

      assert_equal 2, groups.map(&:fingerprint).uniq.length,
        "/lib/ frames at different locations must produce different fingerprints"
    end

    test "exception originating in /lib/ is not bucketed as unknown" do
      exception = make_exception(RuntimeError, "lib error")
      exception.stubs(:backtrace).returns([ "/lib/services/payment_service.rb:15:in 'charge'" ])

      ExceptionCaptureService.capture(exception)
      group = ExceptionGroup.order(:created_at).last

      refute_equal Digest::SHA256.hexdigest("RuntimeError:unknown"), group.fingerprint,
        "/lib/ exception should fingerprint by location, not fall through to unknown"
    end

    test "exception originating in /config/ produces location-based fingerprint" do
      exception = make_exception(RuntimeError, "config error")
      exception.stubs(:backtrace).returns([ "/config/initializers/stripe.rb:5:in 'block in <top>'" ])

      ExceptionCaptureService.capture(exception)
      group = ExceptionGroup.order(:created_at).last

      refute_equal Digest::SHA256.hexdigest("RuntimeError:unknown"), group.fingerprint,
        "/config/ exception should fingerprint by location, not fall through to unknown"
    end

    test "occurrence_count equals the number of successfully persisted occurrences" do
      exception = make_exception(ArgumentError, "count test")

      3.times { ExceptionCaptureService.capture(exception) }

      group = ExceptionGroup.order(:created_at).last

      assert_equal 3, group.occurrence_count
      assert_equal 3, group.occurrences.count,
        "occurrence_count must match the actual number of occurrence rows"
    end

    test "occurrence_count is incremented by the upsert even when occurrence creation fails" do
      exception = make_exception(RuntimeError, "oops")

      ExceptionCaptureService.capture(exception)
      group = ExceptionGroup.order(:created_at).last
      count_before = group.occurrence_count

      # The upsert atomically increments occurrence_count before create_occurrence
      # runs, so a subsequent occurrence insert failure still bumps the counter.
      ExceptionOccurrence.stubs(:create!).raises(ActiveRecord::StatementInvalid, "disk full")
      ExceptionCaptureService.capture(exception)

      assert_equal count_before + 1, group.reload.occurrence_count
    end

    # Upsert — concurrent safety

    test "concurrent captures of the same exception produce exactly one group" do
      exception = make_exception(RuntimeError, "concurrent")
      exception.stubs(:backtrace).returns([ "/app/models/post.rb:77:in 'save'" ])
      fingerprint = Digest::SHA256.hexdigest("RuntimeError:app/models/post.rb#save")

      threads = 5.times.map do
        Thread.new { ExceptionCaptureService.capture(exception) }
      end
      threads.each(&:join)

      assert_equal 1, ExceptionGroup.where(fingerprint: fingerprint).count,
        "ON CONFLICT upsert must not create duplicate groups under concurrent writes"
    end

    test "concurrent captures accumulate occurrence_count correctly" do
      exception = make_exception(RuntimeError, "counter race")
      exception.stubs(:backtrace).returns([ "/app/models/order.rb:12:in 'save'" ])
      fingerprint = Digest::SHA256.hexdigest("RuntimeError:app/models/order.rb#save")

      n = 4
      threads = n.times.map do
        Thread.new { ExceptionCaptureService.capture(exception) }
      end
      threads.each(&:join)

      group = ExceptionGroup.find_by!(fingerprint: fingerprint)

      assert_equal n, group.occurrence_count,
        "each concurrent capture must increment occurrence_count exactly once"
    end

    # Deploy SHA cache

    test "deploy SHA is fetched once and cached within the TTL" do
      ExceptionCaptureService.reset_deploy_sha_cache!
      exception = make_exception(RuntimeError, "cache test")

      scope = stub(first: nil)
      RailsPulse::Deployment.expects(:order).with(started_at: :desc).once.returns(scope)

      2.times { ExceptionCaptureService.capture(exception) }
    end

    test "deploy SHA cache expires after the TTL and re-fetches" do
      ExceptionCaptureService.reset_deploy_sha_cache!

      scope = stub(first: nil)
      RailsPulse::Deployment.expects(:order).with(started_at: :desc).twice.returns(scope)

      ExceptionCaptureService.capture(make_exception(RuntimeError, "before expiry"))

      travel_to(Time.current + ExceptionCaptureService::DEPLOY_SHA_TTL + 1) do
        ExceptionCaptureService.capture(make_exception(RuntimeError, "after expiry"))
      end
    end

    # Lifecycle

    test "does not create an occurrence for an ignored group but still updates count and last_seen_at" do
      exception = make_exception(RuntimeError, "ignored lifecycle")
      ExceptionCaptureService.capture(exception)
      group = ExceptionGroup.order(:created_at).last
      group.update!(status: "ignored")
      count_before = group.occurrence_count
      occurrence_count_before = group.occurrences.count
      last_seen_before = group.last_seen_at

      travel_to(1.minute.from_now) do
        assert_no_difference -> { ExceptionOccurrence.where(exception_group: group).count } do
          ExceptionCaptureService.capture(exception)
        end
      end

      group.reload

      assert_equal "ignored", group.status
      assert_equal occurrence_count_before, group.occurrences.count
      assert_equal count_before + 1, group.occurrence_count
      assert_operator group.last_seen_at, :>, last_seen_before
    end

    test "reopens a resolved group when a new occurrence arrives" do
      exception = make_exception(RuntimeError, "resolved lifecycle")
      ExceptionCaptureService.capture(exception)
      group = ExceptionGroup.order(:created_at).last
      group.update!(status: "resolved", resolved_at: 1.hour.ago)

      assert_difference -> { ExceptionOccurrence.where(exception_group: group).count }, 1 do
        ExceptionCaptureService.capture(exception)
      end

      group.reload

      assert_equal "open", group.status
      assert_nil group.resolved_at
    end

    # Request params

    test "stores filtered request params when capture_exception_params is enabled" do
      original = RailsPulse.configuration.capture_exception_params
      RailsPulse.configuration.capture_exception_params = true
      exception = make_exception(RuntimeError, "params test")

      ExceptionCaptureService.capture(
        exception,
        request_params: { "q" => "search", "password" => "secret", "controller" => "posts" }
      )

      occurrence = ExceptionOccurrence.order(:created_at).last

      assert_equal "search", occurrence.request_params["q"]
      assert_equal "[FILTERED]", occurrence.request_params["password"]
      assert_equal "posts", occurrence.request_params["controller"]
    ensure
      RailsPulse.configuration.capture_exception_params = original
    end

    test "does not store request params when capture_exception_params is false" do
      original = RailsPulse.configuration.capture_exception_params
      RailsPulse.configuration.capture_exception_params = false
      exception = make_exception(RuntimeError, "no params")

      ExceptionCaptureService.capture(exception, request_params: { "q" => "search" })

      occurrence = ExceptionOccurrence.order(:created_at).last

      assert_not occurrence.request_params.present?
    ensure
      RailsPulse.configuration.capture_exception_params = original
    end

    test "drops request params larger than the size limit after filtering" do
      original = RailsPulse.configuration.capture_exception_params
      RailsPulse.configuration.capture_exception_params = true
      exception = make_exception(RuntimeError, "huge params")
      huge = { "blob" => "x" * (ExceptionCaptureService::PARAMS_SIZE_LIMIT + 100) }

      ExceptionCaptureService.capture(exception, request_params: huge)

      occurrence = ExceptionOccurrence.order(:created_at).last

      assert_not occurrence.request_params.present?
    ensure
      RailsPulse.configuration.capture_exception_params = original
    end

    # Location / fingerprint path normalization

    test "stores a Rails.root-relative location on the group" do
      exception = make_exception(RuntimeError, "location")
      exception.stubs(:backtrace).returns([ "#{Rails.root}/app/models/post.rb:77:in 'save'" ])

      ExceptionCaptureService.capture(exception)
      group = ExceptionGroup.order(:created_at).last

      assert_equal "app/models/post.rb#save", group.location
      assert_equal Digest::SHA256.hexdigest("RuntimeError:app/models/post.rb#save"), group.fingerprint
    end

    test "fingerprints two release prefixes as the same group" do
      exception_a = make_exception(RuntimeError, "deploy a")
      exception_b = make_exception(RuntimeError, "deploy b")
      exception_a.stubs(:backtrace).returns([ "/var/www/app/releases/20260101120000/app/models/post.rb:77:in 'save'" ])
      exception_b.stubs(:backtrace).returns([ "/var/www/app/releases/20260102120000/app/models/post.rb:10:in 'save'" ])

      ExceptionCaptureService.capture(exception_a)
      assert_no_difference -> { ExceptionGroup.count } do
        ExceptionCaptureService.capture(exception_b)
      end
    end

    test "does not treat a project path containing ruby as a gem frame" do
      exception = make_exception(RuntimeError, "ruby app")
      exception.stubs(:backtrace).returns([ "/Users/dev/ruby_app/app/models/user.rb:3:in 'call'" ])

      ExceptionCaptureService.capture(exception)
      group = ExceptionGroup.order(:created_at).last

      assert_equal "app/models/user.rb#call", group.location
      refute_equal Digest::SHA256.hexdigest("RuntimeError:unknown"), group.fingerprint
    end

    test "is a no-op when track_exceptions is disabled" do
      original = RailsPulse.configuration.track_exceptions
      RailsPulse.configuration.track_exceptions = false
      exception = make_exception(RuntimeError, "disabled")

      assert_no_difference -> { ExceptionGroup.count } do
        ExceptionCaptureService.capture(exception)
      end
    ensure
      RailsPulse.configuration.track_exceptions = original
    end
  end
end
