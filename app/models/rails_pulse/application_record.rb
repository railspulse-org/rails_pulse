module RailsPulse
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    connects_to(**RailsPulse.connects_to) if RailsPulse.connects_to

    # A central has one shard per application and none to fall back on, so a
    # query outside RailsPulse::Central.with_application raises instead of
    # reading or writing whichever application is listed first.
    self.default_shard = RailsPulse::Central::NO_APPLICATION if RailsPulse::Central.enabled?
  end
end
