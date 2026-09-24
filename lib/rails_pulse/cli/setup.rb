require_relative "base_command"

module RailsPulse
  module CLI
    class Setup < BaseCommand
      STATUS_COLORS = {
        "ok"              => :green,
        "pending"         => :cyan,
        "suggested"       => :yellow,
        "missing"         => :red,
        "needs_attention" => :red
      }.freeze

      desc "check", "Check what still needs configuring and get data-driven suggestions"
      long_desc <<~DESC
        Reads the deployed configuration and the last week of performance data and
        lists what still needs doing: alert thresholds backtested against real traffic,
        deployment regression detection, quiet hours, the sender address, the weekly
        summary email, and whether the scheduled jobs are actually running.

        Each finding has a status (ok, pending, suggested, missing, needs_attention),
        a reason, and a snippet with the file it belongs in. Nothing is changed;
        apply the snippets yourself and deploy. Delivery targets are never returned;
        snippets use REPLACE_WITH_EMAIL and REPLACE_WITH_HOST placeholders.

        Run it a week after install, and again every few months to retune.

        Use --json for the structured response, ideal for piping to an AI agent.
      DESC
      option :days, type: :numeric, default: 7,     desc: "Days of history to analyse (1–30)"
      option :json, type: :boolean, default: false, desc: "Output raw JSON"
      def check
        with_error_handling do
          result = client.get("/setup", { days: options[:days] })

          if options[:json]
            puts JSON.pretty_generate(result)
          else
            render_plan(result)
          end
        end
      end

      private

      def render_plan(data)
        window = data["window"] || {}
        findings = data["findings"] || []

        say ""
        say "Rails Pulse Pro setup check — phase: #{data["phase"]}", :bold
        say "#{window["hours_with_data"]} of #{window["expected_hours"]} hours of summaries, #{window["total_requests"]} requests"
        say ""

        findings.each do |finding|
          say "  #{finding["status"].ljust(15)}  #{finding["key"]}", STATUS_COLORS.fetch(finding["status"], nil)
          say "                   #{finding["reason"]}"
        end

        actionable = findings.select { |f| f["snippet"] }
        unless actionable.empty?
          say ""
          say "SNIPPETS", :bold
          actionable.each do |finding|
            say ""
            say "  # #{finding["key"]} → #{finding["file"]}", :yellow
            finding["snippet"].each_line { |line| say "  #{line.chomp}" }
          end
        end

        say ""
        say data["next_check"].to_s
        say ""
      end
    end
  end
end
