class UserDeviceLogJob < ApplicationJob
  queue_as :default

  def perform(http_user_agent, remote_ip, user_id, fingerprint, type)
    UserDevice.add(
      http_user_agent,
      remote_ip,
      user_id,
      fingerprint,
      type,
    )
  end
end
