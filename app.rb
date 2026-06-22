require 'sinatra'
require 'sinatra/json'
require 'sequel'
require 'json'
require 'securerandom'
require 'time'

set :port, 4567
set :bind, '0.0.0.0'

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

helpers do
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
    tickets = Ticket.where(table_type: table_type, status: STATUS_WAITING)
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

  def average_dining_minutes(table_type)
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

  def estimate_wait_minutes(ticket)
    return 0 unless ticket.status == STATUS_WAITING
    ahead_count = [ticket.queue_position - 1, 0].max
    avg_minutes = average_dining_minutes(ticket.table_type)
    (ahead_count * avg_minutes).round(0).to_i
  end

  def build_ticket_response(ticket, ahead_count = nil)
    wait_minutes = estimate_wait_minutes(ticket)
    avg_minutes = average_dining_minutes(ticket.table_type)
    resp = {
      ticket_no: ticket.ticket_no,
      token: ticket.token,
      table_type: ticket.table_type,
      is_vip: ticket.is_vip,
      status: ticket.status,
      created_at: to_iso8601(ticket.created_at),
      called_at: to_iso8601(ticket.called_at),
      estimated_wait_minutes: wait_minutes,
      avg_dining_minutes: avg_minutes
    }
    resp[:ahead_count] = ahead_count unless ahead_count.nil?
    resp[:queue_position] = ticket.queue_position if ticket.status == STATUS_WAITING
    resp
  end
end

before do
  content_type :json
end

post '/api/tickets' do
  table_type = params[:table_type]
  is_vip = params[:is_vip] == 'true' || params[:is_vip] == true

  unless TABLE_TYPES.include?(table_type)
    status 400
    return json error: 'Invalid table_type, must be "small" or "large"'
  end

  ticket_no = generate_ticket_no(table_type, is_vip)
  token = generate_token

  waiting_count = Ticket.where(table_type: table_type, status: STATUS_WAITING).count
  vip_ahead = Ticket.where(table_type: table_type, status: STATUS_WAITING, is_vip: true).count

  if is_vip
    queue_position = vip_ahead + 1
  else
    queue_position = waiting_count + 1
  end

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

  ahead_count = [ticket.queue_position - 1, 0].max

  status 201
  json build_ticket_response(ticket, ahead_count)
end

get '/api/tickets/:token' do
  token = params[:token]
  ticket = Ticket.where(token: token).first

  unless ticket
    status 404
    return json error: 'Ticket not found'
  end

  ahead_count = if ticket.status == STATUS_WAITING
                  [ticket.queue_position - 1, 0].max
                else
                  0
                end

  json build_ticket_response(ticket, ahead_count)
end

post '/api/kitchen/call' do
  table_type = params[:table_type]

  unless TABLE_TYPES.include?(table_type)
    status 400
    return json error: 'Invalid table_type, must be "small" or "large"'
  end

  ticket = Ticket.where(table_type: table_type, status: STATUS_WAITING)
                 .order(Sequel.desc(:is_vip), :created_at)
                 .first

  unless ticket
    status 404
    return json error: 'No waiting tickets'
  end

  ticket.update(status: STATUS_CALLED, called_at: Time.now)
  recalculate_positions(table_type)

  remaining = Ticket.where(table_type: table_type, status: STATUS_WAITING).count

  json(
    ticket_no: ticket.ticket_no,
    table_type: ticket.table_type,
    is_vip: ticket.is_vip,
    remaining_waiting: remaining
  )
end

post '/api/kitchen/complete' do
  ticket_no = params[:ticket_no]
  ticket = Ticket.where(ticket_no: ticket_no).first

  unless ticket
    status 404
    return json error: 'Ticket not found'
  end

  unless [STATUS_CALLED, STATUS_WAITING].include?(ticket.status)
    status 400
    return json error: "Cannot complete ticket with status: #{ticket.status}"
  end

  was_waiting = ticket.status == STATUS_WAITING
  ticket.update(status: STATUS_COMPLETED, completed_at: Time.now)
  recalculate_positions(ticket.table_type) if was_waiting

  json(
    ticket_no: ticket.ticket_no,
    status: ticket.status,
    completed_at: to_iso8601(ticket.completed_at)
  )
end

post '/api/tickets/:token/cancel' do
  token = params[:token]
  ticket = Ticket.where(token: token).first

  unless ticket
    status 404
    return json error: 'Ticket not found'
  end

  unless ticket.status == STATUS_WAITING
    status 400
    return json error: "Cannot cancel ticket with status: #{ticket.status}"
  end

  ticket.update(status: STATUS_CANCELLED)
  recalculate_positions(ticket.table_type)

  json(
    ticket_no: ticket.ticket_no,
    status: ticket.status
  )
end

get '/api/queue/:table_type' do
  table_type = params[:table_type]

  unless TABLE_TYPES.include?(table_type)
    status 400
    return json error: 'Invalid table_type, must be "small" or "large"'
  end

  waiting_tickets = Ticket.where(table_type: table_type, status: STATUS_WAITING)
                          .order(Sequel.desc(:is_vip), :created_at)
                          .map do |t|
    {
      ticket_no: t.ticket_no,
      is_vip: t.is_vip,
      queue_position: t.queue_position,
      created_at: to_iso8601(t.created_at)
    }
  end

  json(
    table_type: table_type,
    waiting_count: waiting_tickets.size,
    waiting_tickets: waiting_tickets
  )
end

get '/api/stats/daily' do
  date_str = params[:date]
  stat_date = date_str ? Date.parse(date_str) : Date.today

  stats = DailyStat.where(stat_date: stat_date).order(:hour_slot, :table_type).all

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

  currently_waiting_small = Ticket.where(table_type: 'small', status: STATUS_WAITING).count
  currently_waiting_large = Ticket.where(table_type: 'large', status: STATUS_WAITING).count

  json(
    date: stat_date.iso8601,
    summary: {
      total_tickets: total_small + total_large,
      total_small: total_small,
      total_large: total_large,
      total_vip: total_vip,
      currently_waiting_small: currently_waiting_small,
      currently_waiting_large: currently_waiting_large,
      peak_hour: peak_hour_slot,
      peak_hour_count: peak_hour_count
    },
    hourly: by_hour
  )
end

get '/api/health' do
  json status: 'ok', time: Time.now.iso8601
end
