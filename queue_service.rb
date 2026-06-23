# frozen_string_literal: true

require 'securerandom'
require 'time'

module QueueService
  TABLE_TYPES = %w[small large].freeze
  VALID_STATUSES = %w[waiting called served cancelled missed].freeze
  MAX_MISS = 2
  CALL_TIMEOUT_SECONDS = 180
  AVG_MEAL_MINUTES = { 'small' => 30, 'large' => 45 }.freeze

  def self.take_number(table_type, vip: false)
    ticket_number = next_number(table_type)
    token = SecureRandom.hex(8)

    ticket = QueueTicket.create(
      ticket_token: token,
      ticket_number: ticket_number,
      table_type: table_type,
      vip: vip,
      status: 'waiting',
      position: 0,
      miss_count: 0
    )

    normalize_positions(table_type)
    ticket.refresh
    enrich_ticket(ticket)
  end

  def self.call_next(table_type)
    process_expired_calls(table_type)

    candidate = QueueTicket.where(table_type: table_type, status: 'waiting')
                           .order(:position).first

    return nil unless candidate

    candidate.status = 'called'
    candidate.called_at = Time.now
    candidate.save

    normalize_positions(table_type)
    candidate.refresh
    enrich_ticket(candidate)
  end

  def self.confirm_served(ticket_token)
    ticket = QueueTicket.where(ticket_token: ticket_token, status: 'called').first
    return nil unless ticket

    ticket.status = 'served'
    ticket.served_at = Time.now
    ticket.save

    enrich_ticket(ticket)
  end

  def self.cancel(ticket_token)
    ticket = QueueTicket.where(ticket_token: ticket_token)
                        .where(status: %w[waiting called]).first
    return nil unless ticket

    table_type = ticket.table_type
    ticket.status = 'cancelled'
    ticket.save

    normalize_positions(table_type)
    enrich_ticket(ticket)
  end

  def self.handle_miss(ticket_token)
    ticket = QueueTicket.where(ticket_token: ticket_token, status: 'called').first
    return nil unless ticket

    table_type = ticket.table_type
    result = process_miss(ticket)
    normalize_positions(table_type)
    result.refresh
    enrich_ticket(result)
  end

  def self.status(ticket_token)
    ticket = QueueTicket.where(ticket_token: ticket_token).first
    return nil unless ticket

    enrich_ticket(ticket, include_waiting: true)
  end

  def self.current_queue(table_type: nil)
    scope = QueueTicket.where(status: %w[waiting called])
    scope = scope.where(table_type: table_type) if table_type && TABLE_TYPES.include?(table_type)

    scope.order(:position).map do |t|
      {
        ticket_number: t.ticket_number,
        table_type: t.table_type,
        vip: t.vip,
        status: t.status,
        position: t.position
      }
    end
  end

  def self.summary
    small_waiting = QueueTicket.where(table_type: 'small', status: 'waiting').count
    large_waiting = QueueTicket.where(table_type: 'large', status: 'waiting').count
    current_small = QueueTicket.where(table_type: 'small', status: 'called').order(:called_at).last
    current_large = QueueTicket.where(table_type: 'large', status: 'called').order(:called_at).last

    {
      small: {
        waiting: small_waiting,
        current_serving: current_small&.ticket_number
      },
      large: {
        waiting: large_waiting,
        current_serving: current_large&.ticket_number
      }
    }
  end

  def self.stats(target_date = Date.today)
    day_start = Time.new(target_date.year, target_date.month, target_date.day, 0, 0, 0)
    day_end = day_start + 86400

    total = QueueTicket.where(created_at: day_start...day_end).count
    by_type = {}
    TABLE_TYPES.each do |tt|
      by_type[tt] = QueueTicket.where(table_type: tt, created_at: day_start...day_end).count
    end

    by_status = {}
    VALID_STATUSES.each do |s|
      by_status[s] = QueueTicket.where(status: s, created_at: day_start...day_end).count
    end

    vip_count = QueueTicket.where(vip: true, created_at: day_start...day_end).count

    hourly = (0..23).map do |hour|
      h_start = day_start + hour * 3600
      h_end = h_start + 3600
      count = QueueTicket.where(created_at: h_start...h_end).count
      { hour: hour, count: count }
    end

    avg_wait = nil
    served_tickets = QueueTicket.where(status: 'served', created_at: day_start...day_end)
                                .exclude(called_at: nil).exclude(served_at: nil)
    served = served_tickets.all
    if served.any?
      total_seconds = served.sum { |t| (t.served_at - t.called_at).to_f }
      avg_wait = (total_seconds / served.size).round(1)
    end

    {
      date: target_date.to_s,
      total: total,
      by_type: by_type,
      by_status: by_status,
      vip_count: vip_count,
      hourly: hourly,
      avg_wait_seconds: avg_wait
    }
  end

  def self.vip_insert(table_type)
    ticket_number = next_number(table_type)
    token = SecureRandom.hex(8)

    ticket = QueueTicket.create(
      ticket_token: token,
      ticket_number: ticket_number,
      table_type: table_type,
      vip: true,
      status: 'waiting',
      position: 0,
      miss_count: 0
    )

    normalize_positions(table_type)
    ticket.refresh
    enrich_ticket(ticket)
  end

  def self.valid_table_type?(type)
    TABLE_TYPES.include?(type)
  end

  def self.table_types
    TABLE_TYPES
  end

  private

  def self.normalize_positions(table_type)
    tickets = QueueTicket.where(table_type: table_type, status: 'waiting')
                         .order(:miss_count, Sequel.desc(:vip), :created_at)
    pos = 1
    tickets.each do |t|
      t.position = pos
      t.save(validate: false)
      pos += 1
    end
  end

  def self.next_number(table_type)
    today = Date.today
    counter = DailyCounter.find_or_create(table_type: table_type, date: today) do |c|
      c.counter = 0
    end
    counter.counter += 1
    counter.save
    counter.counter
  end

  def self.waiting_ahead(ticket)
    QueueTicket.where(table_type: ticket.table_type, status: 'waiting')
               .where { position < ticket.position }
               .count
  end

  def self.estimate_wait_minutes(table_type, ahead_count)
    per_table = AVG_MEAL_MINUTES[table_type] || 30
    ahead_count * per_table
  end

  def self.process_expired_calls(table_type)
    cutoff = Time.now - CALL_TIMEOUT_SECONDS
    expired = QueueTicket.where(table_type: table_type, status: 'called')
                         .where { called_at < cutoff }
                         .all
    expired.each { |ticket| process_miss(ticket) }
  end

  def self.process_miss(ticket)
    ticket.miss_count = (ticket.miss_count || 0) + 1
    if ticket.miss_count >= MAX_MISS
      ticket.status = 'missed'
    else
      ticket.status = 'waiting'
      ticket.called_at = nil
    end
    ticket.save
    ticket
  end

  def self.enrich_ticket(ticket, include_waiting: false)
    ahead = ticket.status == 'waiting' ? waiting_ahead(ticket) : 0
    wait_min = ticket.status == 'waiting' ? estimate_wait_minutes(ticket.table_type, ahead) : 0

    base = {
      ticket_token: ticket.ticket_token,
      ticket_number: ticket.ticket_number,
      table_type: ticket.table_type,
      vip: ticket.vip,
      status: ticket.status,
      miss_count: ticket.miss_count,
      position: ticket.position,
      ahead_count: ahead,
      estimated_wait_minutes: wait_min,
      created_at: ticket.created_at&.iso8601,
      called_at: ticket.called_at&.iso8601,
      served_at: ticket.served_at&.iso8601
    }

    if include_waiting
      base[:waiting_count] = QueueTicket.where(table_type: ticket.table_type, status: 'waiting').count
    end

    base
  end
end
