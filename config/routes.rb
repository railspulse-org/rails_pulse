RailsPulse::Engine.routes.draw do
  root to: "dashboard#index"

  resources :routes, only: %i[index show]
  resources :requests, only: %i[index show]
  resources :queries, only: %i[index show] do
    member do
      post :reanalyze
    end
  end
  resources :operations, only: %i[show]
  if RailsPulse.configuration.track_exceptions
    resources :exceptions, only: %i[index show update] do
      resources :occurrences, only: %i[show], controller: "exception_occurrences"
    end
  end

  if RailsPulse.configuration.track_jobs
    resources :jobs, only: %i[index show], param: :id do
      resources :runs, only: %i[index show], controller: "job_runs"
    end
  end
  resource :storage, only: :show, controller: "storage"
  patch "pagination/limit", to: "application#set_pagination_limit", as: :pagination_limit
  patch "settings/global_filters", to: "application#set_global_filters", as: :settings_global_filters
  patch "settings/time_range", to: "application#set_time_range", as: :settings_time_range

  # Tag management
  post "tags/:taggable_type/:taggable_id/add", to: "tags#create", as: :add_tag
  delete "tags/:taggable_type/:taggable_id/remove", to: "tags#destroy", as: :remove_tag

  # Deployments are both an API endpoint for CI/CD and a browsable record of
  # what shipped when.
  resources :deployments, only: %i[index show create] do
    collection do
      put :finish
    end
  end

  # Read-only JSON API for the rails-pulse CLI, the MCP server and CI, all
  # authenticated by config.api_token (app/controllers/rails_pulse/api/v1).
  scope path: "api/v1", module: "api/v1", as: :api_v1 do
    resources :routes,      only: :index
    resources :requests,    only: :index
    resources :queries,     only: :index
    resources :jobs,        only: :index
    resources :job_runs,    only: :index
    resources :deployments, only: :index

    # rails_pulse_pro appends the real routes for these. Without it they
    # answer 402 with what is missing, so the CLI and MCP tools can say so
    # instead of 404ing. Keep the list in step with ProController::FEATURES.
    unless RailsPulse.pro?
      %w[alerts alert_rules summary threshold_suggestions setup].each do |feature|
        get feature, to: "pro#show", defaults: { feature: feature }, as: feature
      end
    end
  end

  # CSP compliance testing (development/test only)
  if Rails.env.local?
    get "csp_test", to: "csp_test#show", as: :csp_test
  end

  # Asset serving fallback
  get "rails-pulse-assets/:asset_name", to: "assets#show", as: :asset, constraints: { asset_name: /.*/ }
end
