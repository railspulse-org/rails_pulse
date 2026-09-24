require "test_helper"

module RailsPulse
  module Api
    module V1
      # The endpoints rails_pulse_pro adds answer 402 without it, so the CLI
      # and MCP tools can explain what is missing instead of 404ing.
      class ProControllerTest < ActionDispatch::IntegrationTest
        VALID_TOKEN = "test-api-token"
        HEADERS = { "X-Rails-Pulse-Token" => VALID_TOKEN }.freeze

        setup do
          RailsPulse.configuration.api_token = VALID_TOKEN
        end

        teardown do
          RailsPulse.configuration.api_token = nil
        end

        PATHS = {
          "alerts"                => -> { rails_pulse.api_v1_alerts_path },
          "alert_rules"           => -> { rails_pulse.api_v1_alert_rules_path },
          "summary"               => -> { rails_pulse.api_v1_summary_path },
          "threshold_suggestions" => -> { rails_pulse.api_v1_threshold_suggestions_path },
          "setup"                 => -> { rails_pulse.api_v1_setup_path }
        }.freeze

        test "every Pro endpoint has a stub route" do
          assert_equal ProController::FEATURES.keys.sort, PATHS.keys.sort
        end

        test "answers 402 with the feature, a message and a link" do
          PATHS.each do |feature, path|
            get instance_exec(&path), headers: HEADERS
            body = JSON.parse(response.body)

            assert_response :payment_required, feature
            assert_equal "requires_pro", body["error"]
            assert_equal feature, body["feature"]
            assert_includes body["message"], "Rails Pulse Pro"
            assert_equal ProController::URL, body["url"]
          end
        end

        test "still requires the API token" do
          get rails_pulse.api_v1_alerts_path

          assert_response :unauthorized
        end
      end
    end
  end
end
