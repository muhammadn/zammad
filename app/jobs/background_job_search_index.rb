# Copyright (C) 2012-2016 Zammad Foundation, http://zammad-foundation.org/
class BackgroundJobSearchIndex < ApplicationJob
  queue_as :search_index

  def perform(object, o_id)
    record = object.constantize.lookup(id: o_id)
    return if !exists?(record)
    record.search_index_update_backend
  end

  private

  def exists?(record)
    return true if record
    Rails.logger.info "Can't index #{object}.lookup(id: #{o_id}), no such record found"
    false
  end
end
