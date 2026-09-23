require_relative "lib/rails_pulse/version"

Gem::Specification.new do |spec|
  spec.name        = "rails_pulse"
  spec.version     = RailsPulse::VERSION
  spec.authors     = [ "Scott Harvey" ]
  spec.email       = [ "hey@railspulse.com" ]
  spec.homepage    = "https://railspulse.com"
  spec.summary     = "Self-hosted performance monitoring engine for Rails apps."
  spec.description = "Self-hosted performance monitoring engine for Rails apps. Tracks slow requests, N+1 queries, and SQL performance. All data stays in your own database — no third-party cloud required."
  spec.license     = "MIT"

  # The floors are the oldest versions CI runs (.github/workflows/test.yml and
  # Appraisals): every version the gemspec allows has a test cell. Ruby 3.2 is
  # where the writer's heartbeat loop's Queue#pop(timeout:) and the subscribers'
  # Thread.each_caller_location both arrived.
  spec.required_ruby_version = ">= 3.2.0"

  # Allow pushing to RubyGems.org
  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = "https://railspulse.com"
  spec.metadata["source_code_uri"] = "https://github.com/railspulse/rails_pulse"
  spec.metadata["changelog_uri"] = "https://github.com/railspulse/rails_pulse/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://railspulse.com/documentation/installation"
  spec.metadata["bug_tracker_uri"] = "https://github.com/railspulse/rails_pulse/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Keep this manifest exclusive as well as inclusive. The globs read the working
  # tree, not git, so build artifacts that are gitignored locally (notably *.map,
  # ~24 MB of source maps) would otherwise be published. Directories are rejected
  # so the entry count reflects real files.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,exe,lib,public,vendor}/**/*", "MIT-LICENSE", "CHANGELOG.md", "README.md"]
      .reject { |f| File.directory?(f) }
      .reject { |f| f.end_with?(".map") }
      .reject { |f| f.start_with?("vendor/assets/") }
      .reject { |f| f.start_with?("config/brakeman") }
      # The CSP test page is mounted only when Rails.env.local?, so its script
      # is unreachable in a published gem. Keep it in the repo for development
      # and the csp_compliance system test, but do not ship it.
      .reject { |f| f == "public/rails-pulse-assets/csp-test.js" }
  end

  spec.bindir = "exe"
  spec.executables = [ "rails_pulse_server" ]

  spec.post_install_message = <<~MSG
    Rails Pulse #{spec.version} installed.

    UPGRADING from any 0.3.x? This release changes route identity and DROPS
    rails_pulse_routes.method. Back up your database first, then run:

      rails generate rails_pulse:upgrade
      rails db:migrate                  # separate Pulse DB: rails db:migrate:rails_pulse
      rails rails_pulse:migrate_routes  # REQUIRED - migrate alone leaves Action empty

    Then restart ALL processes together. A rolling restart that leaves old
    processes against the new schema breaks tracking and the routes dashboard.
    Separate database: set schema_dump: false and delete db/rails_pulse_structure.sql.
    Exception tracking is inserted as disabled; set track_exceptions = true to opt in.

    New install? Run: rails generate rails_pulse:install
    Changelog: https://github.com/railspulse/rails_pulse/blob/main/CHANGELOG.md
  MSG

  spec.add_dependency "rails", ">= 7.2.0", "< 9.0.0"
  spec.add_dependency "ransack", ">= 4.0", "< 6"

  spec.add_development_dependency "sqlite3", ">= 1.4"
  spec.add_development_dependency "pg", ">= 1.1"
  spec.add_development_dependency "mysql2", "~> 0.5"

  spec.add_development_dependency "importmap-rails"
  spec.add_development_dependency "css-zero", "~> 1.1", ">= 1.1.4"
  spec.add_development_dependency "rails-controller-testing", ">= 1.0"
  spec.add_development_dependency "minitest", ">= 5.0"
  spec.add_development_dependency "ostruct"
end
