require "test_helper"

module RailsPulse
  module Api
    module V1
      class DeploymentSerializerTest < ActiveSupport::TestCase
        setup do
          @deployment = RailsPulse::Deployment.create!(
            revision: "0123456789abcdef", started_at: 2.hours.ago, finished_at: 2.hours.ago + 75.5,
            metadata: { "branch" => "main" }.to_json
          )
        end

        test "serializes deployment fields" do
          result = DeploymentSerializer.serialize(@deployment)

          assert_equal @deployment.id, result[:id]
          assert_equal "0123456789abcdef", result[:revision]
          assert_equal "0123456789ab", result[:short_revision]
          assert_in_delta 75.5, result[:duration_seconds]
          assert_not result[:in_progress]
          assert_equal({ "branch" => "main" }, result[:metadata])
          assert_nil result[:regression]
        end

        test "returns a hash with exactly the expected keys" do
          result = DeploymentSerializer.serialize(@deployment)

          assert_equal %i[id revision short_revision started_at finished_at duration_seconds in_progress metadata regression], result.keys
        end

        test "serializes an in-progress deployment" do
          @deployment.update!(finished_at: nil)
          result = DeploymentSerializer.serialize(@deployment)

          assert result[:in_progress]
          assert_nil result[:duration_seconds]
        end

        test "passes an attached regression check through untouched" do
          regression = { outcome: "triggered", results: [ { metric: "error_rate" } ] }
          result = DeploymentSerializer.serialize(@deployment, regression: regression)

          assert_equal regression, result[:regression]
        end
      end
    end
  end
end
