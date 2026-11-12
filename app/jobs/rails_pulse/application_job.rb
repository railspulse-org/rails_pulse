module RailsPulse
  class ApplicationJob < ActiveJob::Base
    # Rails Pulse's jobs work on its tables. In remote mode this application
    # has none, and the central summarizes and cleans up what it sends, so
    # each job is a no-op here. A central runs each job once per application,
    # in that application's database; one application's failure does not
    # keep the others from running, and is raised once they have.
    around_perform do |_job, block|
      if RailsPulse::Remote.enabled?
        nil
      elsif RailsPulse::Central.enabled? && RailsPulse::Central.current_application.nil?
        RailsPulse::Central.each_application { block.call }
      else
        block.call
      end
    end
  end
end
