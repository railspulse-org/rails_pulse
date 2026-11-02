class CreateRailsPulseBaselines < ActiveRecord::Migration[7.0]
  def change
    return if table_exists?(:rails_pulse_baselines)

    create_table :rails_pulse_baselines do |t|
      # What normal looks like for one route, query or job, built from its summaries
      t.references :subject, polymorphic: true, null: false, index: false, comment: "Link to Route, Query or Job"
      t.decimal :p50_ms, precision: 15, scale: 6, comment: "Median duration in milliseconds"
      t.decimal :p90_ms, precision: 15, scale: 6, comment: "90th percentile duration in milliseconds"
      t.decimal :p95_ms, precision: 15, scale: 6, comment: "95th percentile duration in milliseconds"
      t.integer :sample_count, default: 0, null: false, comment: "Requests, operations or runs the baseline was built from"
      t.integer :periods, default: 0, null: false, comment: "Summary periods the baseline was built from"
      t.datetime :computed_at, null: false, comment: "When the baseline was last rebuilt"
      t.timestamps
    end

    add_index :rails_pulse_baselines, [ :subject_type, :subject_id ],
      unique: true,
      name: "index_rails_pulse_baselines_on_subject"
  end
end
