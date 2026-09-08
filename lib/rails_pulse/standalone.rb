# frozen_string_literal: true

module RailsPulse
  # Process-wide "am I the standalone dashboard?" flag, set by
  # lib/rails_pulse_server.ru once the host environment is loaded.
  #
  # Two things differ when the engine is served by its own process instead of
  # mounted inside the host app, and both are decided here rather than left to
  # the host to work around:
  #
  # * URL generation. Engine path helpers ask the host's route set where the
  #   engine is mounted and prefix that path — `/rails_pulse/routes` — because
  #   that is what a link inside the host app needs. (`mount` extends the
  #   engine route set with a `find_script_name` that does this.) The
  #   standalone server serves the engine at `/`, so that prefix 404s against
  #   itself. `standalone!` prepends an override that answers "" while the
  #   flag is set, so every helper generates root-relative paths in this
  #   process only. Passing `script_name: ""` or setting it in
  #   `default_url_options` is not enough: Rails treats the empty value as
  #   unset and falls through to the mount prefix.
  #
  # * Authentication. See ApplicationController#authenticate_rails_pulse_user!
  #   — host session hooks cannot run here, so the dashboard falls back to
  #   `config.standalone_authentication_method`, then HTTP Basic.
  module Standalone
    module RootScriptName
      def find_script_name(options)
        RailsPulse.standalone? ? "" : super
      end
    end

    def standalone?
      @standalone == true
    end

    def standalone!
      @standalone = true
      routes = Engine.routes
      routes.singleton_class.prepend(RootScriptName) unless routes.singleton_class.ancestors.include?(RootScriptName)
    end

    # Undo standalone! — for tests that load the rackup file in-process. The
    # prepended override stays but defers to the mount prefix again.
    def exit_standalone!
      @standalone = false
      @host_authentication_ignored_noted = false
    end

    # ApplicationController logs a one-line notice when the standalone
    # dashboard ignores the host's authentication_method / authorize hooks.
    # Returns true the first time it is called in this process (log now),
    # false afterwards. Process-wide on purpose: a per-controller flag
    # repeats the notice for every engine controller a visitor reaches.
    def note_host_authentication_ignored!
      return false if @host_authentication_ignored_noted

      @host_authentication_ignored_noted = true
    end
  end

  extend Standalone
end
