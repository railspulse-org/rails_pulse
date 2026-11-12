Rails.application.routes.draw do
  if RailsPulse::Central.enabled?
    # A central, as the README sets one up (rake test_central).
    post "/rails_pulse/v1/batches", to: "rails_pulse/central/batches#create"
    get "/rails_pulse", to: "rails_pulse/central/applications#index", as: :rails_pulse_applications
    mount RailsPulse::Engine, at: "/:rails_pulse_application", as: :rails_pulse,
          constraints: RailsPulse::Central.route_constraints
  else
    mount RailsPulse::Engine => "/rails_pulse"
  end

  root "home#index"

  get "fast", to: "home#fast"
  get "slow", to: "home#slow"
  get  "errors",       to: "home#errors"
  post "errors/raise", to: "home#raise_error", as: :raise_error
  get "search", to: "home#search"
  get "api_simple", to: "home#api_simple"
  get "api_complex", to: "home#api_complex"

  get  "jobs",         to: "jobs#index"
  post "jobs/trigger", to: "jobs#trigger", as: :trigger_job

  get  "exceptions_test",        to: "exceptions_test#index",     as: :exceptions_test
  post "exceptions_test/raise",  to: "exceptions_test#raise_exception", as: :raise_test_exception

  get  "sign_in", to: "home#index"
  post "sign_in", to: "home#index"

  get  "users", to: "home#index"
  post "users", to: "home#create"

  # Simulate Devise/Warden constraints that touch request env (used by RouteRecognizer tests).
  constraints(->(req) { req.env["warden"].authenticated? }) do
    get "warden_protected", to: "home#index"
  end
  constraints(->(req) { !req.env["warden"].authenticated? }) do
    get "warden_public", to: "home#index"
  end

  get "posts", to: "home#index", as: :posts
  get "posts/:id", to: "home#index", as: :post
  get "partners/:client_id/submissions/:uuid", to: "home#index", as: :partner_submission
end
