class ActiveSupport::TimeWithZone
  include GlobalID::Identification

  alias id to_i
  def self.find(seconds_since_epoch)
    Time.zone.at.utc(seconds_since_epoch.to_i)
  end
end

class Time
  include GlobalID::Identification

  alias id to_i
  def self.find(seconds_since_epoch)
    Time.at.utc(seconds_since_epoch.to_i)
  end
end
