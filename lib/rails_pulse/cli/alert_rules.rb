require_relative "base_command"
require_relative "formatter"

module RailsPulse
  module CLI
    class AlertRules < BaseCommand
      COLUMNS = [
        [ "Name",      30, :name ],
        [ "Type",       9, :type ],
        [ "Metric",    18, :metric ],
        [ "Op",         3, :operator ],
        [ "Threshold", 10, :threshold ],
        [ "Enabled",    7, :enabled ],
        [ "Fired 7d",   8, :trigger_count_7d ],
        [ "Cooldown",   8, :in_cooldown ]
      ].freeze

      desc "list", "List configured alert rules and their current state"
      long_desc <<~DESC
        Returns the alert rules defined in the Rails Pulse Pro initializer, with each
        rule's last trigger time, 7-day trigger count, and cooldown state.

        Delivery targets (email addresses, webhook URLs) are never returned.

        Use --json to also get quiet hours and deployment regression settings.
      DESC
      option :json, type: :boolean, default: false, desc: "Output raw JSON including config and meta"
      def list
        with_error_handling do
          result = client.get("/alert_rules")
          rows = result["data"].map { |rule| rule.merge(rule["state"] || {}) }
          Formatter.render(result.merge("data" => rows), json: options[:json], columns: COLUMNS)
        end
      end
    end
  end
end
