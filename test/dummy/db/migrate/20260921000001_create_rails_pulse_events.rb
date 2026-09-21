class CreateRailsPulseEvents < ActiveRecord::Migration[7.0]
  def change
    return if table_exists?(:rails_pulse_events)

    create_table :rails_pulse_events do |t|
      t.string   :kind,        null: false, comment: "What noticed it: writer_heartbeat; rails_pulse_pro adds alert_rule, deployment_regression, exception_alert, job_heartbeat"
      t.string   :subject,                  comment: "Who it is about: host:pid, rule name, job name, exception class"
      t.string   :outcome,     null: false, comment: "sampled, triggered, clean, insufficient_data, ran"
      t.decimal  :value,       precision: 15, scale: 6, comment: "The number behind it: requests dropped since the last sample, or the triggered metric value"
      t.datetime :occurred_at, null: false
      t.text     :message
      t.text     :metadata,                 comment: "JSON with the kind-specific detail"
      t.timestamps
    end

    add_index :rails_pulse_events, [ :kind, :occurred_at ],
      name: "index_rp_events_on_kind_and_occurred_at"
    add_index :rails_pulse_events, [ :kind, :subject, :occurred_at ],
      name: "index_rp_events_on_kind_subject_and_occurred_at"
  end
end
