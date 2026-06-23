# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/json'
require 'sequel'
require 'json'
require 'securerandom'
require 'time'

DB = Sequel.connect('sqlite://queue.db')

Sequel.extension :migration

Sequel.migration do
  up do
    create_table? :queue_tickets do
      primary_key :id
      String :ticket_token, null: false, unique: true
      Integer :ticket_number, null: false
      String :table_type, null: false
      TrueClass :vip, default: false
      String :status, default: 'waiting'
      Integer :position, default: 0
      Integer :miss_count, default: 0
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :called_at
      DateTime :served_at
    end

    unless DB[:queue_tickets].columns.include?(:miss_count)
      alter_table :queue_tickets do
        add_column :miss_count, Integer, default: 0
      end
    end

    create_table? :daily_counters do
      primary_key :id
      String :table_type, null: false
      Integer :counter, default: 0
      Date :date, null: false
      unique [:table_type, :date]
    end
  end

  down do
    drop_table? :queue_tickets
    drop_table? :daily_counters
  end
end.apply(DB, :up)

class QueueTicket < Sequel::Model(:queue_tickets)
  plugin :timestamps, update_on_create: true
end

class DailyCounter < Sequel::Model(:daily_counters)
end

class QueueApp < Sinatra::Base
  helpers Sinatra::JSON

  before '/api/*' do
    content_type :json
  end

  TABLE_TYPES = %w[small large].freeze
  VALID_STATUSES = %w[waiting called served cancelled missed].freeze
  MAX_MISS = 2
  CALL_TIMEOUT_SECONDS = 180
  AVG_MEAL_MINUTES = { 'small' => 30, 'large' => 45 }.freeze

  def today
    Date.today
  end

  def next_number(table_type)
    counter = DailyCounter.find_or_create(table_type: table_type, date: today) do |c|
      c.counter = 0
    end
    counter.counter += 1
    counter.save
    counter.counter
  end

  def current_max_position(table_type)
    QueueTicket.where(table_type: table_type, status: 'waiting').max(:position) || 0
  end

  def waiting_ahead(ticket)
    QueueTicket.where(table_type: ticket.table_type, status: 'waiting')
               .where { position < ticket.position }
               .count
  end

  def assign_position_bottom(table_type)
    current_max_position(table_type) + 1
  end

  def assign_position_top(table_type)
    min_pos = QueueTicket.where(table_type: table_type, status: 'waiting').min(:position)
    if min_pos
      new_pos = min_pos - 1
    else
      1
    end
    new_pos
  end

  def process_expired_calls(table_type)
    cutoff = Time.now - CALL_TIMEOUT_SECONDS
    expired = QueueTicket.where(table_type: table_type, status: 'called')
                         .where { called_at < cutoff }
                         .all
    expired.each do |ticket|
      handle_miss(ticket)
    end
  end

  def handle_miss(ticket)
    ticket.miss_count = (ticket.miss_count || 0) + 1
    if ticket.miss_count >= MAX_MISS
      ticket.status = 'missed'
    else
      ticket.status = 'waiting'
      ticket.position = assign_position_bottom(ticket.table_type)
      ticket.called_at = nil
    end
    ticket.save
    ticket
  end

  def estimate_wait_minutes(table_type, ahead_count)
    per_table = AVG_MEAL_MINUTES[table_type] || 30
    ahead_count * per_table
  end

  post '/api/queue/take' do
    body = request.body.read
    params = JSON.parse(body) rescue {}

    table_type = params['table_type']
    vip = params['vip'] || false

    unless TABLE_TYPES.include?(table_type)
      status 400
      return json error: 'invalid table_type, must be small or large'
    end

    ticket_number = next_number(table_type)
    position = vip ? assign_position_top(table_type) : assign_position_bottom(table_type)
    token = SecureRandom.hex(8)

    ticket = QueueTicket.create(
      ticket_token: token,
      ticket_number: ticket_number,
      table_type: table_type,
      vip: vip,
      status: 'waiting',
      position: position,
      miss_count: 0
    )

    ahead = waiting_ahead(ticket)
    wait_min = estimate_wait_minutes(table_type, ahead)

    status 201
    json \
      ticket_token: ticket.ticket_token,
      ticket_number: ticket.ticket_number,
      table_type: ticket.table_type,
      vip: ticket.vip,
      position: ticket.position,
      ahead_count: ahead,
      estimated_wait_minutes: wait_min,
      status: ticket.status,
      created_at: ticket.created_at.iso8601
  end

  post '/api/queue/call_next' do
    body = request.body.read
    params = JSON.parse(body) rescue {}

    table_type = params['table_type']

    unless TABLE_TYPES.include?(table_type)
      status 400
      return json error: 'invalid table_type, must be small or large'
    end

    process_expired_calls(table_type)

    vip_waiting = QueueTicket.where(table_type: table_type, status: 'waiting', vip: true).order(:position).first

    candidate = vip_waiting || QueueTicket.where(table_type: table_type, status: 'waiting').order(:position).first

    unless candidate
      status 404
      return json error: 'no one waiting in queue'
    end

    candidate.status = 'called'
    candidate.called_at = Time.now
    candidate.save

    json \
      ticket_token: candidate.ticket_token,
      ticket_number: candidate.ticket_number,
      table_type: candidate.table_type,
      vip: candidate.vip,
      miss_count: candidate.miss_count,
      status: candidate.status,
      called_at: candidate.called_at.iso8601
  end

  post '/api/queue/miss' do
    body = request.body.read
    params = JSON.parse(body) rescue {}

    token = params['ticket_token']

    ticket = QueueTicket.where(ticket_token: token, status: 'called').first

    unless ticket
      status 404
      return json error: 'no called ticket found with this token'
    end

    result = handle_miss(ticket)

    json \
      ticket_token: result.ticket_token,
      ticket_number: result.ticket_number,
      table_type: result.table_type,
      miss_count: result.miss_count,
      status: result.status,
      new_position: result.status == 'waiting' ? result.position : nil
  end

  post '/api/queue/confirm_served' do
    body = request.body.read
    params = JSON.parse(body) rescue {}

    token = params['ticket_token']

    ticket = QueueTicket.where(ticket_token: token, status: 'called').first

    unless ticket
      status 404
      return json error: 'no called ticket found with this token'
    end

    ticket.status = 'served'
    ticket.served_at = Time.now
    ticket.save

    json \
      ticket_token: ticket.ticket_token,
      ticket_number: ticket.ticket_number,
      status: ticket.status,
      served_at: ticket.served_at.iso8601
  end

  post '/api/queue/cancel' do
    body = request.body.read
    params = JSON.parse(body) rescue {}

    token = params['ticket_token']

    ticket = QueueTicket.where(ticket_token: token).where(status: %w[waiting called]).first

    unless ticket
      status 404
      return json error: 'no active ticket found with this token'
    end

    ticket.status = 'cancelled'
    ticket.save

    json \
      ticket_token: ticket.ticket_token,
      ticket_number: ticket.ticket_number,
      status: ticket.status
  end

  get '/api/queue/status/:ticket_token' do
    ticket = QueueTicket.where(ticket_token: params[:ticket_token]).first

    unless ticket
      status 404
      return json error: 'ticket not found'
    end

    ahead = ticket.status == 'waiting' ? waiting_ahead(ticket) : 0
    wait_min = ticket.status == 'waiting' ? estimate_wait_minutes(ticket.table_type, ahead) : 0

    waiting_count = QueueTicket.where(table_type: ticket.table_type, status: 'waiting').count

    json \
      ticket_token: ticket.ticket_token,
      ticket_number: ticket.ticket_number,
      table_type: ticket.table_type,
      vip: ticket.vip,
      status: ticket.status,
      miss_count: ticket.miss_count,
      ahead_count: ahead,
      estimated_wait_minutes: wait_min,
      waiting_count: waiting_count,
      created_at: ticket.created_at.iso8601,
      called_at: ticket.called_at&.iso8601,
      served_at: ticket.served_at&.iso8601
  end

  get '/api/queue/current' do
    table_type = params['table_type']

    scope = QueueTicket.where(status: %w[waiting called])
    scope = scope.where(table_type: table_type) if table_type && TABLE_TYPES.include?(table_type)

    tickets = scope.order(:position).map do |t|
      {
        ticket_number: t.ticket_number,
        table_type: t.table_type,
        vip: t.vip,
        status: t.status,
        position: t.position
      }
    end

    json tickets: tickets
  end

  post '/api/queue/vip_insert' do
    body = request.body.read
    params = JSON.parse(body) rescue {}

    table_type = params['table_type']

    unless TABLE_TYPES.include?(table_type)
      status 400
      return json error: 'invalid table_type, must be small or large'
    end

    ticket_number = next_number(table_type)
    position = assign_position_top(table_type)
    token = SecureRandom.hex(8)

    ticket = QueueTicket.create(
      ticket_token: token,
      ticket_number: ticket_number,
      table_type: table_type,
      vip: true,
      status: 'waiting',
      position: position,
      miss_count: 0
    )

    ahead = waiting_ahead(ticket)
    wait_min = estimate_wait_minutes(table_type, ahead)

    status 201
    json \
      ticket_token: ticket.ticket_token,
      ticket_number: ticket.ticket_number,
      table_type: ticket.table_type,
      vip: true,
      position: ticket.position,
      ahead_count: ahead,
      estimated_wait_minutes: wait_min,
      status: ticket.status,
      created_at: ticket.created_at.iso8601
  end

  get '/api/queue/stats' do
    date_str = params['date']
    target_date = date_str ? Date.parse(date_str) : today

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
      {
        hour: hour,
        count: count
      }
    end

    avg_wait = nil
    served_tickets = QueueTicket.where(status: 'served', created_at: day_start...day_end).exclude(called_at: nil).exclude(served_at: nil)
    served = served_tickets.all
    if served.any?
      total_seconds = served.sum do |t|
        (t.served_at - t.called_at).to_f
      end
      avg_wait = (total_seconds / served.size).round(1)
    end

    json \
      date: target_date.to_s,
      total: total,
      by_type: by_type,
      by_status: by_status,
      vip_count: vip_count,
      hourly: hourly,
      avg_wait_seconds: avg_wait
  end

  get '/api/queue/summary' do
    small_waiting = QueueTicket.where(table_type: 'small', status: 'waiting').count
    large_waiting = QueueTicket.where(table_type: 'large', status: 'waiting').count
    current_small = QueueTicket.where(table_type: 'small', status: 'called').order(:called_at).last
    current_large = QueueTicket.where(table_type: 'large', status: 'called').order(:called_at).last

    json \
      small: {
        waiting: small_waiting,
        current_serving: current_small&.ticket_number
      },
      large: {
        waiting: large_waiting,
        current_serving: current_large&.ticket_number
      }
  end

  run! if app_file == $0
end
