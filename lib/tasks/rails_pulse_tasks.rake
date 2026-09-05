namespace :rails_pulse do
  desc "Copies Rails Pulse migrations to the application."
  task :install_migrations do
    RailsPulse::Installers::MigrationInstaller.install
  end

  desc "Copies Rails Pulse example configuration to the application."
  task :install_config do
    RailsPulse::Installers::ConfigInstaller.install
  end

  desc "Runs all install tasks for Rails Pulse (migrations and config)."
  task install: [ :install_migrations, :install_config ]

  desc "Performs data cleanup based on configured retention policies."
  task cleanup: :environment do
    success = RailsPulse::Tasks::CleanupTaskRunner.run
    exit 1 unless success
  end

  desc "Shows current table sizes and cleanup configuration."
  task cleanup_stats: :environment do
    RailsPulse::Stats::CleanupStatsReporter.report
  end

  desc "Reports schema, migration, route backfill and initializer state for this install; exits 1 when something needs action."
  task status: :environment do
    exit 1 unless RailsPulse::Tasks::StatusReporter.report
  end

  desc "Migrate existing routes: backfill controller actions, normalize paths, consolidate multi-verb routes."
  task migrate_routes: :environment do
    ca_results = RailsPulse::RouteControllerActionBackfiller.call
    puts "Controller action backfill: #{ca_results[:updated]} updated, #{ca_results[:merged]} merged, #{ca_results[:skipped]} skipped, #{ca_results[:already_set]} already set"

    path_results = RailsPulse::RouteMigrator.call
    puts "Path normalization: #{path_results[:merged]} merged, #{path_results[:skipped]} skipped, #{path_results[:unchanged]} unchanged"

    begin
      RailsPulse::RouteIndexes.ensure_null_action_uniqueness!(RailsPulse::Route.connection)
      puts "Ensured unique index on unrecognized (null controller_action) paths."
    rescue ActiveRecord::RecordNotUnique => e
      puts "Duplicate null-action paths detected after consolidation — retrying..."
      # A request between consolidation and index creation may have inserted a duplicate.
      # Re-run the backfiller to merge it, then retry the index once.
      RailsPulse::RouteControllerActionBackfiller.call
      begin
        RailsPulse::RouteIndexes.ensure_null_action_uniqueness!(RailsPulse::Route.connection)
        puts "Unique index created on retry."
      rescue ActiveRecord::RecordNotUnique
        duplicates = RailsPulse::Route.where(controller_action: nil)
          .group(:path).having("COUNT(*) > 1").pluck(:path)
        puts "ERROR: Could not create unique index. Duplicate paths remain:"
        duplicates.each { |p| puts "  - #{p}" }
        puts "Manually resolve these duplicates, then re-run this task."
      end
    end
  end
end
