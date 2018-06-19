# Copyright (C) 2012-2016 Zammad Foundation, http://zammad-foundation.org/

class Transaction::TransactionJob < ApplicationJob
  queue_as :default

  def perform(item, params = {})
    Setting.where(area: 'Transaction::Backend::Async').order(:name).each do |setting|
      backend = Setting.get(setting.name)
      next if params[:disable]&.include?(backend)
      backend = Kernel.const_get(backend)
      Observer::Transaction.execute_singel_backend(backend, item, params)
    end
  end

  def self.run(item, params = {})
    generic = new(item, params)
    generic.perform
  end

end
