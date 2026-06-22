class QueueItem < Sequel::Model
  plugin :validation_helpers

  def validate
    super
    validates_includes %w[large small], :table_type
    validates_includes %w[waiting called completed cancelled expired], :status
  end

  def self.generate_queue_number(table_type, vip)
    prefix = vip ? 'V' : (table_type == 'large' ? 'A' : 'B')
    items = where(Sequel.like(:queue_number, "#{prefix}%"))
            .where(Sequel[:created_at] >= Date.today)
            .all
    max_num = items.map { |item| item.queue_number[1..-1].to_i }.max || 0
    "#{prefix}#{sprintf('%03d', max_num + 1)}"
  end

  def self.next_waiting(table_type)
    where(table_type: table_type, status: 'waiting')
      .order(Sequel.desc(:vip), Sequel.desc(:priority), Sequel.asc(:created_at))
      .first
  end

  def self.count_ahead(customer_token)
    item = where(customer_token: customer_token).first
    return nil unless item

    waiting = where(table_type: item.table_type, status: 'waiting')
              .order(Sequel.desc(:vip), Sequel.desc(:priority), Sequel.asc(:created_at))
              .all

    index = waiting.index { |w| w.id == item.id }
    index || 0
  end

  def self.expire_timeout!(timeout_seconds = 180)
    now = Time.now
    threshold = now - timeout_seconds
    items = where(status: 'called')
            .where(Sequel[:called_at] <= threshold)
            .all
    items.each do |item|
      item.update(status: 'expired')
    end
    items.size
  end

  def self.estimate_wait_time(table_type, ahead_count)
    (ahead_count + 1) * 15
  end
end
