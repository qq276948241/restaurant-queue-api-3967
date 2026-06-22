require 'sequel'
require 'securerandom'
require 'time'

DB = Sequel.sqlite('queue.db')

unless DB.table_exists?(:tickets)
  DB.create_table :tickets do
    primary_key :id
    String :ticket_no, null: false, unique: true
    String :token, null: false, unique: true
    String :table_type, null: false
    TrueClass :is_vip, default: false
    String :status, default: 'waiting'
    Integer :queue_position
    DateTime :created_at
    DateTime :called_at
    DateTime :completed_at
  end
end

unless DB.table_exists?(:daily_stats)
  DB.create_table :daily_stats do
    primary_key :id
    Date :stat_date, null: false
    Integer :hour_slot, null: false
    String :table_type, null: false
    Integer :ticket_count, default: 0
    Integer :vip_count, default: 0
  end
end

class Ticket < Sequel::Model
  plugin :timestamps, create: :created_at
end

class DailyStat < Sequel::Model
end

TABLE_TYPES = %w[small large].freeze
STATUS_WAITING = 'waiting'.freeze
STATUS_CALLED = 'called'.freeze
STATUS_COMPLETED = 'completed'.freeze
STATUS_CANCELLED = 'cancelled'.freeze

DEFAULT_AVG_DINING_MINUTES = {
  'small' => 45,
  'large' => 75
}.freeze

HISTORY_WINDOW_DAYS = 7.freeze

class QueueService
  def self.valid_table_type?(type)
    TABLE_TYPES.include?(type)
  end

  def self.table_types
    TABLE_TYPES
  end

  def self.create_ticket(table_type, is_vip)
    ticket_no = generate_ticket_no(table_type, is_vip)
    token = generate_token

    waiting_count = waiting_tickets(table_type).count
    vip_ahead = waiting_tickets(table_type).where(is_vip: true).count

    queue_position = is_vip ? vip_ahead + 1 : waiting_count + 1

    ticket = Ticket.create(
      ticket_no: ticket_no,
      token: token,
      table_type: table_type,
      is_vip: is_vip,
      status: STATUS_WAITING,
      queue_position: queue_position
    )

    recalculate_positions(table_type)
    ticket.reload

    update_daily_stats(table_type, is_vip)

    ticket
  end

  def self.find_ticket_by_token(token)
    Ticket.where(token: token).first
  end

  def self.find_ticket_by_no(ticket_no)
    Ticket.where(ticket_no: ticket_no).first
  end

  def self.ahead_count(ticket)
    return 0 unless ticket.status == STATUS_WAITING
    [ticket.queue_position - 1, 0].max
  end

  def self.call_next(table_type)
    ticket = waiting_tickets(table_type)
               .order(Sequel.desc(:is_vip), :created_at)
               .first

    return nil unless ticket

    ticket.update(status: STATUS_CALLED, called_at: Time.now)
    recalculate_positions(table_type)
    ticket
  end

  def self.complete_ticket(ticket)
    was_waiting = ticket.status == STATUS_WAITING
    ticket.update(status: STATUS_COMPLETED, completed_at: Time.now)
    recalculate_positions(ticket.table_type) if was_waiting
    ticket
  end

  def self.cancel_ticket(ticket)
    ticket.update(status: STATUS_CANCELLED)
    recalculate_positions(ticket.table_type)
    ticket
  end

  def self.can_complete?(ticket)
    [STATUS_CALLED, STATUS_WAITING].include?(ticket.status)
  end

  def self.can_cancel?(ticket)
    ticket.status == STATUS_WAITING
  end

  def self.waiting_tickets(table_type)
    Ticket.where(table_type: table_type, status: STATUS_WAITING)
  end

  def self.waiting_count(table_type)
    waiting_tickets(table_type).count
  end

  def self.queue_list(table_type)
    waiting_tickets(table_type)
      .order(Sequel.desc(:is_vip), :created_at)
      .map do |t|
      {
        ticket_no: t.ticket_no,
        is_vip: t.is_vip,
        queue_position: t.queue_position,
        created_at: to_iso8601(t.created_at)
      }
    end
  end

  def self.daily_stats(date = Date.today)
    stats = DailyStat.where(stat_date: date).order(:hour_slot, :table_type).all

    by_hour = {}
    (0..23).each do |h|
      by_hour[h.to_s.rjust(2, '0')] = {
        small: { total: 0, vip: 0 },
        large: { total: 0, vip: 0 },
        total: 0
      }
    end

    total_small = 0
    total_large = 0
    total_vip = 0

    stats.each do |s|
      slot = s.hour_slot.to_s.rjust(2, '0')
      type = s.table_type.to_sym
      by_hour[slot][type][:total] = s.ticket_count || 0
      by_hour[slot][type][:vip] = s.vip_count || 0
      by_hour[slot][:total] += s.ticket_count || 0

      if s.table_type == 'small'
        total_small += s.ticket_count || 0
      else
        total_large += s.ticket_count || 0
      end
      total_vip += s.vip_count || 0
    end

    peak_hour = by_hour.max_by { |_, v| v[:total] }
    peak_hour_slot = peak_hour ? peak_hour[0] : nil
    peak_hour_count = peak_hour ? peak_hour[1][:total] : 0

    {
      date: date.iso8601,
      summary: {
        total_tickets: total_small + total_large,
        total_small: total_small,
        total_large: total_large,
        total_vip: total_vip,
        currently_waiting_small: waiting_count('small'),
        currently_waiting_large: waiting_count('large'),
        peak_hour: peak_hour_slot,
        peak_hour_count: peak_hour_count
      },
      hourly: by_hour
    }
  end

  def self.serialize_ticket(ticket)
    wait_minutes = estimate_wait_minutes(ticket)
    avg_minutes = average_dining_minutes(ticket.table_type)
    ahead = ahead_count(ticket)

    resp = {
      ticket_no: ticket.ticket_no,
      token: ticket.token,
      table_type: ticket.table_type,
      is_vip: ticket.is_vip,
      status: ticket.status,
      created_at: to_iso8601(ticket.created_at),
      called_at: to_iso8601(ticket.called_at),
      estimated_wait_minutes: wait_minutes,
      avg_dining_minutes: avg_minutes,
      ahead_count: ahead
    }
    resp[:queue_position] = ticket.queue_position if ticket.status == STATUS_WAITING
    resp
  end

  def self.serialize_call_result(ticket)
    {
      ticket_no: ticket.ticket_no,
      table_type: ticket.table_type,
      is_vip: ticket.is_vip,
      remaining_waiting: waiting_count(ticket.table_type)
    }
  end

  def self.serialize_complete_result(ticket)
    {
      ticket_no: ticket.ticket_no,
      status: ticket.status,
      completed_at: to_iso8601(ticket.completed_at)
    }
  end

  def self.serialize_cancel_result(ticket)
    {
      ticket_no: ticket.ticket_no,
      status: ticket.status
    }
  end

  def self.average_dining_minutes(table_type)
    since = Date.today - HISTORY_WINDOW_DAYS
    completed = Ticket.where(
      table_type: table_type,
      status: STATUS_COMPLETED
    ).where { completed_at >= since }.all

    durations = completed.filter_map do |t|
      next unless t.called_at && t.completed_at
      (t.completed_at.to_time - t.called_at.to_time) / 60.0
    end

    if durations.size >= 3
      (durations.sum / durations.size).round(1)
    else
      DEFAULT_AVG_DINING_MINUTES[table_type].to_f
    end
  end

  def self.estimate_wait_minutes(ticket)
    return 0 unless ticket.status == STATUS_WAITING
    ahead = ahead_count(ticket)
    avg_minutes = average_dining_minutes(ticket.table_type)
    (ahead * avg_minutes).round(0).to_i
  end

  class << self
    private

    def generate_ticket_no(table_type, is_vip)
      prefix = is_vip ? 'V' : (table_type == 'large' ? 'L' : 'S')
      today = Date.today.strftime('%Y%m%d')
      seq = (Ticket.where(Sequel.like(:ticket_no, "#{prefix}#{today}%")).count + 1).to_s.rjust(4, '0')
      "#{prefix}#{today}#{seq}"
    end

    def generate_token
      SecureRandom.hex(16)
    end

    def recalculate_positions(table_type)
      tickets = waiting_tickets(table_type)
                  .order(Sequel.desc(:is_vip), :created_at)
      tickets.each_with_index do |t, idx|
        t.update(queue_position: idx + 1)
      end
    end

    def update_daily_stats(table_type, is_vip)
      now = Time.now
      stat_date = now.to_date
      hour_slot = now.hour
      stat = DailyStat.where(stat_date: stat_date, hour_slot: hour_slot, table_type: table_type).first
      if stat
        stat.update(ticket_count: (stat.ticket_count || 0) + 1)
        stat.update(vip_count: (stat.vip_count || 0) + 1) if is_vip
      else
        DailyStat.create(
          stat_date: stat_date,
          hour_slot: hour_slot,
          table_type: table_type,
          ticket_count: 1,
          vip_count: is_vip ? 1 : 0
        )
      end
    end

    def to_iso8601(obj)
      return nil if obj.nil?
      obj.is_a?(DateTime) ? obj.to_time.iso8601 : obj.iso8601
    end
  end
end
