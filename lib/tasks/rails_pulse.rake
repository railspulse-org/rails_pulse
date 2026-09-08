require "stringio"

namespace :db do
  namespace :schema do
    desc "Load Rails Pulse schema (for separate database setup only)"
    task load_rails_pulse: :environment do
      schema_file = Rails.root.join("db/rails_pulse_schema.rb")

      # Only load schema if using separate database setup
      if separate_database_setup?
        if schema_file.exist?
          load schema_file
          puts "Rails Pulse schema loaded successfully"
          # Record any copied migrations as already applied so they don't show as
          # pending after a fresh schema load. The schema file creates all tables and
          # columns directly, so the incremental migrations are logically already done.
          record_rails_pulse_migrations_applied
        else
          puts "Rails Pulse schema file not found. Run: rails generate rails_pulse:install --database=separate"
        end
      else
        puts "Single database setup detected. Rails Pulse tables managed via regular migrations."
      end
    end
  end

  # Hook into common database tasks only for separate database setup
  task prepare: :environment do
    Rake::Task["db:schema:load_rails_pulse"].invoke if separate_database_setup?
  end

  task setup: :environment do
    Rake::Task["db:schema:load_rails_pulse"].invoke if separate_database_setup?
  end
end

# Hook into test database preparation so the separate Rails Pulse DB is populated
# for test runs, not just for development/production db:prepare.
# The task may be namespaced as "app:db:schema:load_rails_pulse" in engine context
# vs "db:schema:load_rails_pulse" in a host app — try both.
#
# This fires on every single `rails test` process (once per appraisal/test_matrix
# combination, again for the migration regression process), and after the first
# run it only ever reports "tables already exist" — so its output is muted here.
# The task itself stays fully verbose when invoked directly (installs, upgrades,
# and test/lib/tasks/rails_pulse_test.rb assert on that direct-invocation output).
Rake::Task["db:test:prepare"].enhance do
  if separate_database_setup?
    task_name = %w[db:schema:load_rails_pulse app:db:schema:load_rails_pulse]
      .find { |name| Rake::Task.task_defined?(name) }
    if task_name
      Rake::Task[task_name].reenable
      original_stdout = $stdout
      $stdout = StringIO.new
      begin
        Rake::Task[task_name].invoke
      ensure
        $stdout = original_stdout
      end
    end
  end
end if Rake::Task.task_defined?("db:test:prepare")

# Helper function to detect database setup type
def separate_database_setup?
  # A .keep file alone (created by install_generator for all modes) does not
  # indicate separate-DB. Require actual migration files or a database.yml entry.
  migrate_dir = Rails.root.join("db/rails_pulse_migrate")
  has_migration_files = migrate_dir.exist? && Dir.glob("#{migrate_dir}/*.rb").any?
  has_db_config = Rails.application.config.database_configuration.dig(Rails.env, "rails_pulse").present?
  has_migration_files || has_db_config
end

# After a schema load, insert version numbers for any migration files already in
# db/rails_pulse_migrate/ into schema_migrations so Rails does not report them as
# pending. The schema already includes every column those migrations would add, so
# running them would be a no-op — but Rails still needs the version recorded.
def record_rails_pulse_migrations_applied
  return unless defined?(RailsPulse::ApplicationRecord)

  migrations_path = Rails.root.join("db/rails_pulse_migrate")
  return unless migrations_path.exist?

  connection = RailsPulse::ApplicationRecord.connection

  # Only record versions if the schema load actually created/updated tables.
  # On an existing database, the schema file is a no-op, so marking migrations
  # as applied would hide genuinely pending migrations.
  unless connection.table_exists?(:rails_pulse_routes)
    puts "[RailsPulse] Schema load did not create tables — skipping migration recording"
    return
  end

  # Create schema_migrations if this is a brand-new database that has not yet
  # had any migrations run against it (e.g. just after db:create).
  unless connection.table_exists?(:schema_migrations)
    connection.create_table :schema_migrations, id: false do |t|
      t.string :version, null: false
    end
    connection.add_index :schema_migrations, :version,
      unique: true, name: "unique_schema_migrations"
  end

  Dir.glob("#{migrations_path}/*.rb").sort.each do |file|
    version = File.basename(file, ".rb").split("_").first
    migration_name = File.basename(file, ".rb").sub(/\A\d+_/, "")

    # For the 0.4.0 route-identity migrations, only record them as applied if
    # the schema actually has the columns they would add. This prevents marking
    # them applied on an existing DB where the schema load was a no-op.
    if migration_name.include?("change_rails_pulse_routes") || migration_name.include?("null_action_unique_index")
      unless connection.column_exists?(:rails_pulse_routes, :controller_action) &&
             connection.column_exists?(:rails_pulse_routes, :http_methods)
        puts "[RailsPulse] Skipping #{version} — route columns not present yet"
        next
      end
    end

    next if connection.select_values(
      "SELECT version FROM schema_migrations WHERE version = #{connection.quote(version)}"
    ).any?

    connection.execute(
      "INSERT INTO schema_migrations (version) VALUES (#{connection.quote(version)})"
    )
    puts "[RailsPulse] Marked migration #{version} as applied (schema already up to date)"
  end
rescue => e
  warn "[RailsPulse] Could not mark migrations as applied: #{e.message}"
end

namespace :rails_pulse do
  desc "Backfill summary data from existing requests and operations"
  task backfill_summaries: :environment do
    puts "Starting Rails Pulse summary backfill..."

    # Find earliest data
    earliest_request = RailsPulse::Request.minimum(:occurred_at)
    earliest_operation = RailsPulse::Operation.minimum(:occurred_at)

    historical_start_time = if earliest_request && earliest_operation
      [ earliest_request, earliest_operation ].min.beginning_of_day
    elsif earliest_request
      earliest_request.beginning_of_day
    elsif earliest_operation
      earliest_operation.beginning_of_day
    else
      puts "No Rails Pulse data found - skipping summary generation"
      next
    end

    historical_end_time = Time.current

    # Generate hourly and daily summaries from beginning of data
    puts "\nCreating hourly and daily summaries from #{historical_start_time.strftime('%B %d, %Y')} to #{historical_end_time.strftime('%B %d, %Y')}"
    RailsPulse::BackfillSummariesJob.perform_now(historical_start_time, historical_end_time, [ "hour", "day" ])

    puts "\nSummary backfill completed!"
    puts "Total summaries: #{RailsPulse::Summary.count}"
    puts "\nTo keep summaries up to date, schedule RailsPulse::SummaryJob to run hourly"
  end

  desc "Record a deployment event. Usage: rake rails_pulse:record_deployment[revision]"
  task :record_deployment, [ :revision ] => :environment do |_t, args|
    revision = args[:revision]
    abort "ERROR: revision is required. Usage: rake rails_pulse:record_deployment[abc1234]" if revision.blank?

    attributes = { revision: revision, started_at: Time.current }
    metadata = deployment_metadata_from_env
    attributes[:metadata] = metadata if metadata

    deployment = RailsPulse::Deployment.create!(attributes)
    puts "[RailsPulse] Deployment recorded: #{deployment.revision} at #{deployment.started_at}"
  rescue ActiveRecord::RecordInvalid => e
    abort "ERROR: #{e.message}"
  end

  desc "Mark the latest deployment for a revision as finished. Usage: rake rails_pulse:finish_deployment[revision]"
  task :finish_deployment, [ :revision ] => :environment do |_t, args|
    revision = args[:revision]
    abort "ERROR: revision is required. Usage: rake rails_pulse:finish_deployment[abc1234]" if revision.blank?

    deployment = RailsPulse::Deployment.latest_for_revision(revision)
    abort "ERROR: no deployment recorded for revision #{revision}" unless deployment

    deployment.update!(finished_at: Time.current)
    puts "[RailsPulse] Deployment finished: #{deployment.revision} at #{deployment.finished_at} (#{deployment.duration.round}s)"
  rescue ActiveRecord::RecordInvalid => e
    abort "ERROR: #{e.message}"
  end
end

# Optional metadata for rails_pulse:record_deployment, as a JSON object:
#   RAILS_PULSE_DEPLOYMENT_METADATA='{"environment":"production"}'
# Rake splits task arguments on commas, so JSON cannot be passed positionally.
def deployment_metadata_from_env
  raw = ENV["RAILS_PULSE_DEPLOYMENT_METADATA"]
  return nil if raw.blank?

  parsed = JSON.parse(raw)
  abort "ERROR: RAILS_PULSE_DEPLOYMENT_METADATA must be a JSON object" unless parsed.is_a?(Hash)
  parsed.to_json
rescue JSON::ParserError => e
  abort "ERROR: RAILS_PULSE_DEPLOYMENT_METADATA is not valid JSON: #{e.message}"
end
