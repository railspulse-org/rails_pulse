require "bundler/setup"
require "bundler/gem_tasks"

# Load environment variables from .env file
require "dotenv/load" if File.exist?(".env")

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

require "json"
require "fileutils"
require "open3"
require_relative "test/support/rails_pulse_console"

# ---------------------------------------------------------------------------
# Test session output
#
#   ━━ RAILS PULSE ━━━━━━━━━━━━━━━━ sqlite3 · rails 8.1.3.1 · ruby 3.3.6 · seed 19335 ━━
#
#   [ok]  main suite            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  3409/3409  12 workers  30.0s
#   [ok]  migration regression  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━      21/21    1 worker   2.7s
#
#   ━━ PASS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 3,430 tests · 9,368 assertions · 32.8s ━━
#
# Each `rails test` process draws its own row (test/support/rails_pulse_test_reporter.rb)
# and writes its totals to tmp/pulse_test_results/<phase>.json; the session
# wrapper here prints the heading and sums the footer.
# ---------------------------------------------------------------------------

def pulse_seed
  @pulse_seed ||= ENV.fetch("SEED") { rand(1..99_999) }.to_i
end

def pulse_rails_version
  require "rails"
  Rails.version
rescue LoadError
  File.read("Gemfile.lock")[/^    rails \(([^)]+)\)/, 1] || "unknown"
end

def pulse_meta(rails: true)
  parts = [ ENV["DB"] || "sqlite3" ]
  parts << "rails #{pulse_rails_version}" if rails
  parts << "ruby #{RUBY_VERSION}"
  parts << "seed #{pulse_seed}"
  RailsPulseConsole.dim(parts.join(" · "))
end

# Runs one `rails test` process as a labelled row. Never raises: the session
# footer reports the outcome and sets the exit status.
def pulse_phase(label, phase, command, env = {})
  env = env.merge("RAILS_PULSE_TEST_LABEL" => label, "RAILS_PULSE_TEST_PHASE" => phase)
  sh(env, "#{command} --seed #{pulse_seed}", verbose: false) do |ok, _status|
    @pulse_failed = true unless ok
  end
end

def pulse_session(meta, &block)
  return yield if @pulse_session_active

  @pulse_session_active = true
  run_pulse_session(meta, &block)
ensure
  @pulse_session_active = false
end

def run_pulse_session(meta)
  @pulse_failed = false
  FileUtils.rm_rf(RailsPulseConsole::RESULTS_DIR)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  puts
  puts RailsPulseConsole.rule("RAILS PULSE", meta)
  puts
  yield
  puts

  results = Dir[File.join(RailsPulseConsole::RESULTS_DIR, "*.json")].map { |f| JSON.parse(File.read(f)) }
  sum = ->(key) { results.sum { |r| r[key] } }
  failures, errors, skips = sum["failures"], sum["errors"], sum["skips"]
  passed = !@pulse_failed && results.any? && results.all? { |r| r["passed"] } && failures + errors == 0
  left, colour = passed ? [ "PASS", :green ] : [ "FAIL", :red ]

  parts = [ RailsPulseConsole.plural(sum["runs"], "test"), RailsPulseConsole.plural(sum["assertions"], "assertion") ]
  parts << RailsPulseConsole.paint(RailsPulseConsole.plural(failures, "failure"), :red) if failures > 0
  parts << RailsPulseConsole.paint(RailsPulseConsole.plural(errors, "error"), :red) if errors > 0
  parts << RailsPulseConsole.dim("#{skips} skipped") if skips > 0
  parts << RailsPulseConsole.paint("a test process exited early", :red) if @pulse_failed && failures + errors == 0
  parts << RailsPulseConsole.duration(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)

  puts RailsPulseConsole.rule(left, parts.join(RailsPulseConsole.dim(" · ")), color: colour)
  puts
  exit 1 unless passed
end

# Runs `command`, capturing combined stdout/stderr. Silent on success — the
# step's own [ok] row is the whole signal, so a passing RuboCop/Brakeman/npm/
# gem/bundler run doesn't bury it in tool banners. Raises with the captured
# output as the message on failure, so pulse_steps' failure rendering shows
# exactly what the tool printed, with none of the green-path noise mixed in.
def pulse_sh(command, env = {})
  output, status = Open3.capture2e(env, command)
  raise output unless status.success?
end

# Runs a numbered list of [label, block] steps under one heading, printing an
# [ok]/[!!] row for each. A step's block raises to fail it; the remaining
# steps still run. Returns the list of failed labels.
def pulse_steps(title, meta, steps)
  failed = []
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  label_width = steps.map { |label, _| label.length }.max

  puts
  puts RailsPulseConsole.rule(title, meta)

  steps.each_with_index do |(label, block), index|
    puts
    puts "  #{RailsPulseConsole.dim(RailsPulseConsole.counter(index + 1, steps.size))}  #{RailsPulseConsole.bold(label)}"
    step_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      block.call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_started
      puts RailsPulseConsole.line(:ok, "#{label.ljust(label_width)}  #{RailsPulseConsole.dim(format('%7s', RailsPulseConsole.duration(elapsed)))}")
    rescue => e
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_started
      puts RailsPulseConsole.line(:fail, "#{label.ljust(label_width)}  #{RailsPulseConsole.dim(format('%7s', RailsPulseConsole.duration(elapsed)))}")
      e.message.each_line { |line| puts "        #{RailsPulseConsole.paint(line.chomp, :red)}" }
      failed << label
    end
  end

  puts
  left, colour = failed.empty? ? [ "PASS", :green ] : [ "FAIL", :red ]
  parts = [ "#{steps.size - failed.size}/#{steps.size} steps" ]
  parts << RailsPulseConsole.paint(RailsPulseConsole.plural(failed.size, "failure"), :red) if failed.any?
  parts << RailsPulseConsole.duration(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
  puts RailsPulseConsole.rule(left, parts.join(RailsPulseConsole.dim(" · ")), color: colour)
  puts

  failed
end

# rake test_setup regenerates test/dummy/db/schema.rb from whichever adapter it
# ran for, and Rails loads that file, not the migrations, when it prepares the
# parallel-worker databases. A schema.rb dumped from MySQL has no partial-index
# predicate, so the SQLite suite then fails RouteIndexesTest for no visible
# reason. test_setup records the adapter it ran for and `rake test` refuses to
# run against a different one.
TEST_SETUP_MARKER = "tmp/test_setup_adapter"

def normalize_adapter(database)
  case database.to_s.downcase
  when "sqlite", "sqlite3"      then "sqlite3"
  when "mysql", "mysql2"        then "mysql2"
  when "postgres", "postgresql" then "postgresql"
  else database.to_s
  end
end

def record_test_setup_adapter(database)
  FileUtils.mkdir_p(File.dirname(TEST_SETUP_MARKER))
  File.write(TEST_SETUP_MARKER, normalize_adapter(database))
end

def verify_test_setup_adapter!(database)
  wanted = normalize_adapter(database)
  recorded = File.exist?(TEST_SETUP_MARKER) ? File.read(TEST_SETUP_MARKER).strip : nil
  return if recorded == wanted

  puts
  if recorded
    puts RailsPulseConsole.line(:fail, "the test database was last set up for #{recorded}, not #{wanted}; its schema.rb would be loaded into the #{wanted} suite")
  else
    puts RailsPulseConsole.line(:fail, "the test database has not been set up for #{wanted}")
  end
  puts "  Run: DB=#{wanted} rake test_setup"
  puts
  exit 1
end

# Environment-dependent behaviour belongs in Configuration defaults or the
# install template, never in app/: a `Rails.env.test?` branch there is a code
# path the suite cannot see (a screenshot fixture hid behind one for four
# pre-releases). Recording the environment name (Rails.env.to_s) is fine;
# branching on it is not.
APP_ENV_BRANCHING = /Rails\.env(\.\w+\?|\s*==|\s*!=)/

desc "Fail if anything under app/ branches on Rails.env"
task :check_app_env_branching do
  hits = Dir["app/**/*.{rb,erb}"].flat_map do |file|
    File.foreach(file).with_index(1).filter_map do |line, number|
      "#{file}:#{number}: #{line.strip}" if line.match?(APP_ENV_BRANCHING)
    end
  end

  if hits.any?
    puts RailsPulseConsole.line(:fail, "app/ branches on Rails.env; move the environment dependence to Configuration defaults or the install template")
    hits.each { |hit| puts "        #{hit}" }
    exit 1
  end

  puts RailsPulseConsole.line(:ok, "nothing under app/ branches on Rails.env")
end

desc "Verify dummy app migrations are in sync with gem migrations"
task :verify_dummy_migrations do
  # Check if db/rails_pulse_migrate directory exists (separate database setup)
  if Dir.exist?("db/rails_pulse_migrate")
    gem_migrations = Dir["db/rails_pulse_migrate/*.rb"].map { |f| File.basename(f) }.sort

    # Get all migrations from dummy app
    dummy_migrations = Dir["test/dummy/db/migrate/*.rb"].map { |f| File.basename(f) }

    missing = gem_migrations - dummy_migrations

    if missing.any?
      puts RailsPulseConsole.line(:fail, "dummy app is missing #{RailsPulseConsole.plural(missing.size, 'migration')}")
      missing.each { |m| puts "        #{RailsPulseConsole.dim(m)}" }
      puts
      puts "  To fix this, run:"
      puts "    cd test/dummy"
      puts "    rails generate rails_pulse:upgrade"
      puts "    rails db:migrate RAILS_ENV=test"
      puts
      puts "  Then commit the new migration files."
      exit 1
    else
      puts RailsPulseConsole.line(:ok, "dummy app migrations are in sync with gem migrations")
    end
  else
    puts RailsPulseConsole.line(:ok, "migration sync check skipped (single database setup)")
  end
end

desc "Sync Rails Pulse schema to test/dummy app"
task :sync_test_schema do
  source = "db/rails_pulse_schema.rb"
  dest = "test/dummy/db/rails_pulse_schema.rb"

  if File.exist?(source)
    FileUtils.cp(source, dest)
    puts RailsPulseConsole.line(:ok, "synced schema #{RailsPulseConsole.dim("#{source} -> #{dest}")}")
  else
    puts RailsPulseConsole.line(:warn, "source schema not found: #{source}")
  end
end

desc "Setup database for testing"
task :test_setup do
  database = ENV["DB"] || "sqlite3"

  command = case database.downcase
  when "sqlite3", "sqlite"
    "RAILS_ENV=test bin/rails db:drop db:create db:migrate"
  when "mysql2", "mysql"
    "DB=mysql2 MYSQL_PASSWORD=#{ENV.fetch('MYSQL_PASSWORD', '')} RAILS_ENV=test rails db:drop db:create db:migrate"
  when "postgresql", "postgres"
    "DB=postgresql RAILS_ENV=test rails db:drop db:create db:migrate"
  end

  puts
  puts RailsPulseConsole.rule("TEST SETUP", RailsPulseConsole.dim(database))
  puts

  begin
    raise "unknown database: #{database} (supported: sqlite3, mysql2, postgresql)" unless command

    Rake::Task[:sync_test_schema].invoke

    schema_file = "test/dummy/db/schema.rb"
    if File.exist?(schema_file)
      File.delete(schema_file)
      puts RailsPulseConsole.line(:ok, "removed stale schema.rb")
    end

    sh command, verbose: false
    record_test_setup_adapter(database)
    puts RailsPulseConsole.line(:ok, "#{database} database ready")
    puts
    puts "  Ready to run: rake test"
  rescue => e
    puts RailsPulseConsole.line(:fail, "database setup failed")
    e.message.each_line { |line| puts "        #{RailsPulseConsole.paint(line.chomp, :red)}" }
    puts
    puts "  Troubleshooting:"
    puts "    • Ensure #{database} is installed and running"
    puts "    • Check database credentials in test/dummy/config/database.yml"
    puts "    • Verify RAILS_ENV=test environment is configured"
    exit 1
  end
  puts
end

desc "Run migration regression tests in an isolated process"
task :test_migrations do
  pulse_session(pulse_meta(rails: false)) do
    # Migration regression tests run DDL against historical schema snapshots;
    # coverage is meaningless there, and the SimpleCov per-file gate would fail
    # on rake task files that load but never execute in that process.
    pulse_phase("migration regression", "migrations", "rails test test/migrations", "COVERAGE" => nil)
  end
end

desc "Run test suite"
task :test do
  verify_test_setup_adapter!(ENV["DB"] || "sqlite3")

  pulse_session(pulse_meta) do
    pulse_phase("main suite", "main", "rails test test/controllers test/generators test/helpers test/instrumentation test/jobs test/lib test/middleware test/models test/serializers test/services test/rails_pulse_test.rb test/tracker_test.rb")
    Rake::Task[:test_migrations].invoke
  end
end

desc "Run test suite with code coverage"
task :test_coverage do
  ENV["COVERAGE"] = "true"
  Rake::Task[:test].invoke

  puts RailsPulseConsole.rule("COVERAGE", RailsPulseConsole.dim("open coverage/index.html for the full report"))
  puts
end

# Prepares the dummy app's database for one database/Rails combination.
# quiet: true (used by test_matrix) suppresses this method's own heading and
# per-line output entirely — the caller's own row already reports pass/fail
# for the whole combination, so a nested "TEST SETUP" box here would just be
# another layer of chrome around nothing new. On failure, quiet mode raises
# with the setup failure wrapped around the captured command output instead
# of printing locally, so pulse_steps shows it once, in the right place.
def perform_test_setup_for_version(database, rails_version, quiet: false)
  unless quiet
    puts
    puts RailsPulseConsole.rule("TEST SETUP", RailsPulseConsole.dim("#{database} · #{rails_version.tr('-', ' ')}"))
    puts
  end

  begin
    source = "db/rails_pulse_schema.rb"
    dest = "test/dummy/db/rails_pulse_schema.rb"
    FileUtils.cp(source, dest) if File.exist?(source)
    puts RailsPulseConsole.line(:ok, "synced schema #{RailsPulseConsole.dim("#{source} -> #{dest}")}") unless quiet

    schema_file = "test/dummy/db/schema.rb"
    if File.exist?(schema_file)
      File.delete(schema_file)
      puts RailsPulseConsole.line(:ok, "removed stale schema.rb") unless quiet
    end

    # RUBYOPT=-W0 silences duplicate-constant warnings from Ruby loading two
    # different rdoc versions across the root and per-Rails-version Gemfile.locks.
    pulse_sh("bundle exec appraisal #{rails_version} rails db:drop db:create db:migrate RAILS_ENV=test",
      "DB" => database, "RUBYOPT" => "-W0")
    record_test_setup_adapter(database)
    puts RailsPulseConsole.line(:ok, "#{database} + #{rails_version.tr('-', ' ')} database ready") unless quiet
  rescue => e
    if quiet
      raise "database setup failed:\n#{e.message}"
    else
      puts RailsPulseConsole.line(:fail, "database setup failed")
      e.message.each_line { |line| puts "        #{RailsPulseConsole.paint(line.chomp, :red)}" }
      raise
    end
  end
  puts unless quiet
end

desc "Setup database for specific Rails version and database"
task :test_setup_for_version, [ :database, :rails_version ] do |t, args|
  perform_test_setup_for_version(args[:database] || ENV["DB"] || "sqlite3", args[:rails_version] || "rails-8-0")
end

desc "Test all database and Rails version combinations"
task :test_matrix do
  databases = %w[mysql2 postgresql sqlite3]
  rails_versions = %w[rails-7-2 rails-8-0 rails-8-1]
  base_test_paths = "test/controllers test/generators test/helpers test/instrumentation test/jobs test/lib test/middleware test/models test/serializers test/services test/rails_pulse_test.rb test/tracker_test.rb test/system"

  steps = databases.product(rails_versions).map do |database, rails_version|
    label = "#{database} + #{rails_version.tr('-', ' ')}"
    test_env = { "DB" => database, "MYSQL_PASSWORD" => ENV.fetch("MYSQL_PASSWORD", ""), "RUBYOPT" => "-W0" }

    # Each phase can run 30-90s+ with no output of its own (pulse_sh captures
    # it silently so a passing run doesn't bury the step's [ok] row), so a
    # combination with no sub-step marker looks stuck. On a TTY this updates
    # one line in place; otherwise it prints plain lines so CI logs still
    # show forward progress.
    block = -> {
      progress = ->(msg) do
        if RailsPulseConsole.fancy?
          print "\r\e[2K        #{RailsPulseConsole.dim(msg)}"
        else
          puts "        #{msg}"
        end
      end

      begin
        progress.call("setting up database…")
        perform_test_setup_for_version(database, rails_version, quiet: true)

        progress.call("running main suite…")
        pulse_sh("bundle exec appraisal #{rails_version} rails test #{base_test_paths}", test_env)

        progress.call("running migrations…")
        pulse_sh("bundle exec appraisal #{rails_version} rails test test/migrations", test_env)
      ensure
        print "\r\e[2K" if RailsPulseConsole.fancy?
      end
    }
    [ label, block ]
  end

  failed = pulse_steps("TEST MATRIX", RailsPulseConsole.dim("#{steps.size} combinations"), steps)
  exit 1 if failed.any?
end

desc "Pre-release testing with comprehensive checks"
task :test_release do
  public_assets = "public/rails-pulse-assets"
  vendor_css = "vendor/assets/stylesheets"
  vendor_js = "vendor/assets/javascripts"

  verify_assets = -> {
    pulse_sh("npm run build --silent")
    { public_assets => "public assets", vendor_css => "vendor CSS", vendor_js => "vendor JS" }.each do |dir, label|
      raise "#{label} directory is missing or empty (#{dir})" unless Dir.exist?(dir) && !Dir.empty?(dir)
    end
  }

  verify_gem_build = -> {
    begin
      pulse_sh("gem build rails_pulse.gemspec")
    ensure
      Dir.glob("rails_pulse-*.gem").each { |f| File.delete(f) }
    end
  }

  steps = [
    [ "Checking git status", -> {
      git_status = `git status --porcelain`.strip
      raise "working directory is not clean:\n#{git_status}" unless git_status.empty?
    } ],
    [ "Updating appraisal gemfiles", -> { pulse_sh("bundle exec appraisal install") } ],
    [ "Syncing test schema", -> { sh "rake sync_test_schema", verbose: false } ],
    [ "Verifying dummy app migrations", -> { sh "rake verify_dummy_migrations", verbose: false } ],
    [ "Running RuboCop linting", -> { pulse_sh("bundle exec rubocop") } ],
    [ "Checking app/ for Rails.env branching", -> { pulse_sh("bundle exec rake check_app_env_branching") } ],
    [ "Running Brakeman security scanner", -> { sh "rake brakeman", verbose: false } ],
    [ "Installing Node dependencies", -> { pulse_sh("npm install --no-fund --no-audit") } ],
    [ "Running ESLint JS linting", -> { pulse_sh("npm run lint:js --silent") } ],
    [ "Running JavaScript unit tests", -> { pulse_sh("npm run test:js --silent") } ],
    [ "Building production assets", verify_assets ],
    [ "Verifying gem builds correctly", verify_gem_build ],
    [ "Running generator tests", -> { sh "./bin/test_generators", verbose: false } ],
    [ "Running migration regression tests", -> { sh "rake test_migrations", verbose: false } ],
    [ "Running full test matrix", -> { sh "rake test_matrix", verbose: false } ]
  ]

  failed = pulse_steps("RAILS PULSE", RailsPulseConsole.dim("pre-release validation"), steps)

  if failed.empty?
    puts "  Ready for release. Next steps:"
    puts "    1. Update version in lib/rails_pulse/version.rb"
    puts "    2. Update Gemfile.lock files for all Rails versions"
    puts "    3. Follow the release process in docs/releasing.md"
    puts
  else
    puts "  Fix these issues before releasing."
    puts
    exit 1
  end
end

desc "Run Brakeman security scanner"
task :brakeman do
  require "brakeman"

  begin
    result = Brakeman.run(
      app_path: ".",
      config_file: "config/brakeman.yml",
      quiet: true,
      print_report: false,
      pager: false
    )

    # result.filtered_warnings only includes warnings that aren't ignored
    unignored_warnings = result.filtered_warnings
    ignored_count = result.warnings.count - unignored_warnings.count

    puts
    if unignored_warnings.any? || result.errors.any?
      # Only show the full report when there's something to act on — a clean
      # scan doesn't need the check list and file-by-file breakdown repeated.
      puts result.report.format(:to_s)
      puts

      detail = [ RailsPulseConsole.plural(unignored_warnings.count, "warning") ]
      detail << "#{ignored_count} ignored" if ignored_count > 0
      detail << RailsPulseConsole.plural(result.errors.count, "error")
      puts RailsPulseConsole.line(:fail, "security issues found #{RailsPulseConsole.dim(detail.join(' · '))}")
      exit 1
    else
      detail = ignored_count > 0 ? RailsPulseConsole.dim("(#{ignored_count} warnings reviewed and ignored)") : nil
      puts RailsPulseConsole.line(:ok, [ "no security issues found", detail ].compact.join(" "))
    end
  rescue => e
    puts RailsPulseConsole.line(:fail, "brakeman scan failed #{RailsPulseConsole.dim(e.message)}")
    exit 1
  end
end

task default: :test
