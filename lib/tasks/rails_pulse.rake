require "stringio"

namespace :db do
  namespace :schema do
    desc "Load Rails Pulse schema (for separate database setup only)"
    task load_rails_pulse: :environment do
      schema_file = Rails.root.join("db/rails_pulse_schema.rb")

      # A central has one database per application and loads the schema into
      # each one that does not have the tables yet, in every environment this
      # task's callers (db:prepare, db:setup, db:test:prepare) act on.
      if RailsPulse::Central.enabled?
        RailsPulse::Central.load_schema(environments: RailsPulse::Central.task_environments(Rails.env), schema_file: schema_file)
        next
      end

      # Only load schema if using separate database setup
      if separate_database_setup?
        if schema_file.exist?
          load schema_file
          puts "Rails Pulse schema loaded successfully"
          # Present only when the app ran rails_pulse:install_cloud.
          cloud_schema_file = Rails.root.join("db/rails_pulse_cloud_schema.rb")
          if cloud_schema_file.exist?
            load cloud_schema_file
            puts "Rails Pulse Cloud schema loaded successfully"
          end
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

  namespace :rails_pulse do
    # On a central, ahead of db:prepare: every application database it is
    # about to migrate, in development and test alike, gets the schema
    # before Rails runs db/rails_pulse_migrate against it, whose guarded
    # migrations expect the tables to exist.
    task prepare_central_schema: :environment do
      Rake::Task["db:schema:load_rails_pulse"].invoke if RailsPulse::Central.enabled?
    end

    # The same ahead of db:migrate, which migrates this environment only.
    task load_central_schema: :environment do
      RailsPulse::Central.load_schema if RailsPulse::Central.enabled?
    end
  end
end

{ "db:prepare" => "db:rails_pulse:prepare_central_schema", "db:migrate" => "db:rails_pulse:load_central_schema" }.each do |name, prerequisite|
  Rake::Task[name].enhance([ prerequisite ]) if Rake::Task.task_defined?(name)
end

# db:setup and db:reset load each database's schema file, then seed, which
# refuses to run while any migration is pending. A central's application
# databases have no schema file, so they get Rails Pulse's right after.
Rake::Task["db:schema:load"].enhance do
  RailsPulse::Central.load_schema(environments: RailsPulse::Central.task_environments(Rails.env)) if RailsPulse::Central.enabled?
end if Rake::Task.task_defined?("db:schema:load")

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
    each_rails_pulse_database { backfill_rails_pulse_summaries }
  end

  desc "Record a deployment event. Usage: rake rails_pulse:record_deployment[revision]"
  task :record_deployment, [ :revision ] => :environment do |_t, args|
    revision = args[:revision]
    abort "ERROR: revision is required. Usage: rake rails_pulse:record_deployment[abc1234]" if revision.blank?

    attributes = { revision: revision, started_at: Time.current }
    metadata = deployment_metadata_from_env
    attributes[:metadata] = metadata if metadata

    if RailsPulse::Remote.enabled?
      send_deployment_to_central(attributes.merge(action: "record", metadata: metadata && JSON.parse(metadata)))
      next
    end

    deployment = RailsPulse::Deployment.create!(attributes)
    puts "[RailsPulse] Deployment recorded: #{deployment.revision} at #{deployment.started_at}"
  rescue ActiveRecord::RecordInvalid => e
    abort "ERROR: #{e.message}"
  end

  desc "Mark the latest deployment for a revision as finished. Usage: rake rails_pulse:finish_deployment[revision]"
  task :finish_deployment, [ :revision ] => :environment do |_t, args|
    revision = args[:revision]
    abort "ERROR: revision is required. Usage: rake rails_pulse:finish_deployment[abc1234]" if revision.blank?

    if RailsPulse::Remote.enabled?
      send_deployment_to_central(action: "finish", revision: revision, finished_at: Time.current)
      next
    end

    deployment = RailsPulse::Deployment.latest_for_revision(revision)
    abort "ERROR: no deployment recorded for revision #{revision}" unless deployment

    deployment.update!(finished_at: Time.current)
    puts "[RailsPulse] Deployment finished: #{deployment.revision} at #{deployment.finished_at} (#{deployment.duration.round}s)"
  rescue ActiveRecord::RecordInvalid => e
    abort "ERROR: #{e.message}"
  end
end

# The database tasks run once here, or on a central once per application, in
# its database: every application, or only the one RAILS_PULSE_APPLICATION
# names. Returns what each run returned.
def each_rails_pulse_database
  return [ yield ] unless RailsPulse::Central.enabled?

  names = RailsPulse::Central.application_names
  if (only = ENV["RAILS_PULSE_APPLICATION"].presence)
    unless RailsPulse::Central.application?(only)
      abort "ERROR: RAILS_PULSE_APPLICATION=#{only} is not in config.central.applications (#{names.join(', ')})"
    end
    names = [ only.to_sym ]
  end

  names.map do |name|
    puts "== #{name}"
    RailsPulse::Central.with_application(name) { yield }
  end
end

def backfill_rails_pulse_summaries
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
    return
  end

  historical_end_time = Time.current

  # Generate hourly and daily summaries from beginning of data
  puts "\nCreating hourly and daily summaries from #{historical_start_time.strftime('%B %d, %Y')} to #{historical_end_time.strftime('%B %d, %Y')}"
  RailsPulse::BackfillSummariesJob.perform_now(historical_start_time, historical_end_time, [ "hour", "day" ])

  puts "\nSummary backfill completed!"
  puts "Total summaries: #{RailsPulse::Summary.count}"
  puts "\nTo keep summaries up to date, schedule RailsPulse::SummaryJob to run hourly"
end

# In remote mode the deployment goes to the central. A rake task has no
# writer thread to queue it on, so it is sent now, and whoever ran the task
# is told whether the central recorded it.
def send_deployment_to_central(attributes)
  response = RailsPulse::Remote.deliver_now([ RailsPulse::Remote::Item.new("deployment", attributes) ])
  body = response.json
  unless response.status.between?(200, 299) && body["rejected"].to_i.zero?
    abort "ERROR: the central did not record the deployment (HTTP #{response.status}): #{Array(body['errors']).first || response.message}"
  end

  verb = attributes[:action] == "finish" ? "finish" : "start"
  puts "[RailsPulse] Deployment #{verb} sent to the central: #{attributes[:revision]}"
rescue RailsPulse::Remote::Client::Unavailable => e
  abort "ERROR: could not reach the central at #{RailsPulse.configuration.remote.url}: #{e.message}"
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
