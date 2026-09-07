source "https://rubygems.org"

# Specify your gem's dependencies in rails_pulse.gemspec.
gemspec

# Load environment variables from .env file
gem "dotenv-rails", groups: [ :development, :test ]

# Testing dependencies
group :test do
  gem "appraisal"
  gem "puma", "7.2.1"
  gem "capybara"
  gem "minitest-reporters", ">= 1.8.0"
  gem "mocha"
  gem "selenium-webdriver"
  gem "shoulda-matchers"
  gem "simplecov", require: false
  gem "timecop"
end

group :development do
  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
  gem "rubocop-minitest", require: false

  # Security scanning
  gem "brakeman", require: false
end

group :development, :test do
  gem "debug"
end

# Background job adapters — used by the /jobs demo page and adapter tests
group :development, :test do
  gem "sidekiq"
  gem "good_job"
  gem "delayed_job_active_record"
  gem "solid_queue"
  gem "resque"
end
