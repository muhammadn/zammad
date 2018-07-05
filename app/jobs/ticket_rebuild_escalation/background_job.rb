class TicketRebuildEscalation::BackgroundJob < ApplicationJob
  queue_as :default

  def perform
    Cache.delete('SLA::List::Active')
    Ticket::Escalation.rebuild_all
  end
end
