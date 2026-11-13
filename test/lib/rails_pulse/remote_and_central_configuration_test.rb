require "test_helper"

module RailsPulse
  class RemoteAndCentralConfigurationTest < ActiveSupport::TestCase
    TOKEN = "t" * 40

    teardown do
      ENV.delete("RAILS_PULSE_REMOTE_URL")
      ENV.delete("RAILS_PULSE_REMOTE_TOKEN")
    end

    # Remote Settings Tests

    test "remote mode is off until both the URL and the token are set" do
      remote = Configuration.new.remote

      assert_not remote.enabled?

      remote.url = "https://pulse.example.com"

      assert_not remote.enabled?

      remote.token = TOKEN

      assert_predicate remote, :enabled?
    end

    test "the URL and token default to their environment variables, read when first asked for" do
      remote = Configuration.new.remote
      ENV["RAILS_PULSE_REMOTE_URL"] = "https://pulse.example.com"
      ENV["RAILS_PULSE_REMOTE_TOKEN"] = TOKEN

      assert_equal "https://pulse.example.com", remote.url
      assert_equal TOKEN, remote.token
      assert_predicate remote, :enabled?
    end

    test "a value set in the initializer wins over the environment, nil included" do
      ENV["RAILS_PULSE_REMOTE_URL"] = "https://pulse.example.com"
      ENV["RAILS_PULSE_REMOTE_TOKEN"] = TOKEN
      remote = Configuration.new.remote
      remote.url = nil

      assert_not remote.enabled?
    end

    test "the token never shows in inspect" do
      remote = Configuration.new.remote
      remote.token = TOKEN

      assert_not_includes remote.inspect, TOKEN
      assert_includes remote.inspect, "[FILTERED]"
    end

    test "remote settings are validated" do
      assert_raises(ArgumentError) { build_config { remote.url = "pulse.example.com" } }
      assert_raises(ArgumentError) { build_config { remote.url = "ftp://pulse.example.com" } }
      assert_raises(ArgumentError) { build_config { remote.token = 123 } }
    end

    test "a blank URL or token leaves remote mode off instead of failing the boot" do
      config = build_config do
        remote.url = ""
        remote.token = ""
      end

      assert_not config.remote.enabled?
    end

    # Central Settings Tests

    test "central mode is on when at least one application is listed" do
      central = Configuration.new.central

      assert_not central.enabled?

      central.applications = { shop: { token: TOKEN, database: :pulse_shop } }

      assert_predicate central, :enabled?
      assert_equal [ :shop ], central.application_names
    end

    test "each application becomes a shard reading and writing its own database" do
      central = Configuration.new.central
      central.applications = { "shop" => { token: TOKEN, database: "pulse_shop" }, blog: { "token" => "b" * 40, "database" => :pulse_blog } }

      assert_equal({ shards: { shop: { writing: :pulse_shop, reading: :pulse_shop }, blog: { writing: :pulse_blog, reading: :pulse_blog } } },
                   central.connects_to)
    end

    test "RailsPulse.connects_to is the central's shards, after an empty one for outside any application" do
      config = Configuration.new
      config.central.applications = { shop: { token: TOKEN, database: :pulse_shop } }
      RailsPulse.stubs(:configuration).returns(config)

      shards = RailsPulse.connects_to[:shards]

      assert_equal [ RailsPulse::Central::NO_APPLICATION, :shop ], shards.keys
      assert_equal({ writing: :pulse_shop, reading: :pulse_shop }, shards[:shop])
      assert_equal ":memory:", shards[RailsPulse::Central::NO_APPLICATION][:writing].database
    end

    test "tokens never show in inspect" do
      central = Configuration.new.central
      central.applications = { shop: { token: TOKEN, database: :pulse_shop } }

      assert_not_includes central.inspect, TOKEN
    end

    test "central settings are validated" do
      assert_raises(ArgumentError) { build_config { central.applications = [ :shop ] } }
      assert_raises(ArgumentError) { build_config { central.applications = { "Shop!" => { token: TOKEN, database: :pulse_shop } } } }
      assert_raises(ArgumentError) { build_config { central.applications = { shop: { token: "short", database: :pulse_shop } } } }
      assert_raises(ArgumentError) { build_config { central.applications = { shop: { token: TOKEN } } } }
      assert_raises(ArgumentError) { build_config { central.applications = { shop: { token: TOKEN, database: :pulse_shop, url: "x" } } } }
      assert_raises(ArgumentError) { build_config { central.applications = { shop: "pulse_shop" } } }
    end

    test "two applications cannot share a token or a name" do
      error = assert_raises(ArgumentError) do
        build_config { central.applications = { shop: { token: TOKEN, database: :a }, blog: { token: TOKEN, database: :b } } }
      end

      assert_match(/another application's token/, error.message)
      assert_raises(ArgumentError) do
        build_config { central.applications = { shop: { token: TOKEN, database: :a }, "shop" => { token: "c" * 40, database: :b } } }
      end
    end

    test "an application without a token is allowed, so the app boots where secrets are absent or empty" do
      assert_nothing_raised { build_config { central.applications = { shop: { token: nil, database: :pulse_shop } } } }
      assert_nothing_raised { build_config { central.applications = { shop: { token: "", database: :pulse_shop } } } }
    end

    # Mode Tests

    test "remote and central mode exclude each other" do
      error = assert_raises(ArgumentError) do
        build_config do
          remote.url = "https://pulse.example.com"
          remote.token = TOKEN
          central.applications = { shop: { token: TOKEN, database: :pulse_shop } }
        end
      end

      assert_match(/cannot both be on/, error.message)
    end

    test "a central connects its own databases, so connects_to must be left unset" do
      assert_raises(ArgumentError) do
        build_config do
          self.connects_to = { database: { writing: :rails_pulse } }
          central.applications = { shop: { token: TOKEN, database: :pulse_shop } }
        end
      end
    end

    test "Cloud works with neither mode, since it syncs from this database's tables" do
      assert_raises(ArgumentError) do
        build_config do
          cloud.api_key = "rpc_4f9Kx2mQ8vTzL1nB7wYc3HdR6sJe5PaU"
          cloud.application = "shop"
          remote.url = "https://pulse.example.com"
          remote.token = TOKEN
        end
      end
    end

    # Edge Cases

    test "neither mode is on by default" do
      config = Configuration.new

      assert_not config.remote.enabled?
      assert_not config.central.enabled?
      assert_nothing_raised { config.validate_configuration! }
    end

    private

    def build_config(&block)
      config = Configuration.new
      config.instance_eval(&block)
      config.validate_configuration!
      config
    end
  end
end
