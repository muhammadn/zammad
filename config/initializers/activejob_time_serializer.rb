class ActiveSupport::TimeWithZone
  include GlobalID::Identification

  alias id to_i
  def self.find(seconds_since_epoch)
    Time.zone.at(seconds_since_epoch.to_i)
  end
end

class Time
  include GlobalID::Identification

  alias id to_i
  def self.find(seconds_since_epoch)
    # rubocop:disable Rails/TimeZone
    Time.at(seconds_since_epoch.to_i)
    # rubocop:enable Rails/TimeZone
  end
end
