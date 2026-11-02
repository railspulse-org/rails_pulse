class AddP90DurationToRailsPulseSummaries < ActiveRecord::Migration[7.0]
  def change
    return unless table_exists?(:rails_pulse_summaries)

    unless column_exists?(:rails_pulse_summaries, :p90_duration)
      add_column :rails_pulse_summaries, :p90_duration, :float, comment: "90th percentile duration"
    end
  end
end
