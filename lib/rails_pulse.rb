require "rails_pulse/version"
require "rails_pulse/engine"
require "rails_pulse/packaged_assets"
require "rails_pulse/configuration"
require "rails_pulse/paginator"
require "rails_pulse/cleanup_service"
require "rails_pulse/tracker"
require "rails_pulse/standalone"
require "rails_pulse/schema_check"

module RailsPulse
  class << self
    attr_accessor :configuration

    def register_nav_item(label:, path_helper:, icon:, position: 100)
      @nav_items ||= []
      @nav_items << { label: label, path_helper: path_helper, icon: icon, position: position }
      @nav_items.sort_by! { |item| item[:position] }
    end

    def nav_items
      @nav_items || []
    end

    def pro?
      defined?(RailsPulse::Pro) == "constant"
    end

    def configure
      self.configuration ||= Configuration.new
      yield(configuration)
      configuration.validate_configuration!
    end

    def logger
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        @logger ||= ActiveSupport::TaggedLogging.new(Rails.logger).tagged("RailsPulse")
      else
        Logger.new($stdout)
      end
    end

    def clear_metric_cache!
      Rails.cache.delete_matched("rails_pulse_metric*")
    end

    def warm_metric_cache!
      # Pre-warm cache for common metrics
      [ :average_response_times, :percentile_response_times, :request_count_totals, :error_rate_per_route ].each do |metric|
        begin
          logger.info "Warming cache for metric: #{metric}"
          # This would trigger cache generation by making the request
        rescue => e
          logger.error "Failed to warm cache for #{metric}: #{e.message}"
        end
      end
    end

    def connects_to
      configuration&.connects_to
    end
  end

  # Ensure configuration is initialized
  self.configuration ||= Configuration.new
end
