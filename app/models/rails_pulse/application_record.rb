module RailsPulse
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    connects_to(**RailsPulse.connects_to) if RailsPulse.connects_to

    # On a central the shard outside RailsPulse::Central.with_application is
    # an empty database, so a query there fails instead of reading or writing
    # whichever application is listed first.
    self.default_shard = RailsPulse::Central::NO_APPLICATION if RailsPulse::Central.enabled?
  end
end
