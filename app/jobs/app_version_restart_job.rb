class AppVersionRestartJob < ApplicationJob
  queue_as :default

  def perform(cmd)
    Rails.logger.info "executing CMD: #{cmd}"
    system(cmd)
    Rails.logger.info "executed CMD: #{cmd}"
  end
end
