require 'sinatra'
require 'sequel'
require 'json'
require 'securerandom'
require 'date'

DB = Sequel.connect('sqlite://queue.db')
DB.timezone = :local

class QueueTicket < Sequel::Model(DB[:queue_tickets])
  STATUS_WAITING = 'waiting'
  STATUS_CALLED = 'called'
  STATUS_SERVED = 'served'
  STATUS_CANCELLED = 'cancelled'

  TABLE_SMALL = 'small'
  TABLE_LARGE = 'large'

  def before_create
    self.created_at ||= Time.now
    self.status ||= STATUS_WAITING
    self.miss_count ||= 0
    super
  end
end

class DailyCounter < Sequel::Model(DB[:daily_counters])
end

def generate_ticket_token
  SecureRandom.hex(8)
end

def get_next_ticket_number(table_type, date = Date.today)
  counter = DailyCounter.where(table_type: table_type, date: date).first
  if counter
    counter.update(counter: counter.counter + 1)
    counter.counter
  else
    DailyCounter.create(table_type: table_type, date: date, counter: 1)
    1
  end
end

def calculate_position(ticket)
  return 0 unless ticket.status == QueueTicket::STATUS_WAITING

  waiting = QueueTicket.where(
    table_type: ticket.table_type,
    status: QueueTicket::STATUS_WAITING
  )

  if ticket.vip
    ahead_count = waiting.where(vip: true).where { id < ticket.id }.count
  else
    vip_count = waiting.where(vip: true).count
    non_vip_ahead = waiting.where(vip: false).where { id < ticket.id }.count
    ahead_count = vip_count + non_vip_ahead
  end

  ahead_count + 1
end

def find_next_ticket(table_type)
  waiting_tickets = QueueTicket.where(
    table_type: table_type,
    status: QueueTicket::STATUS_WAITING
  ).order(Sequel.desc(:vip), Sequel.asc(:id))

  waiting_tickets.first
end

def get_waiting_count(table_type)
  QueueTicket.where(
    table_type: table_type,
    status: QueueTicket::STATUS_WAITING
  ).count
end

before do
  content_type :json
end

post '/api/tickets' do
  params = JSON.parse(request.body.read) rescue {}

  table_type = params['table_type']
  vip = params['vip'] || false

  unless [QueueTicket::TABLE_SMALL, QueueTicket::TABLE_LARGE].include?(table_type)
    status 400
    return { error: 'Invalid table type. Must be "small" or "large"' }.to_json
  end

  ticket_number = get_next_ticket_number(table_type)
  token = generate_ticket_token

  ticket = QueueTicket.create(
    ticket_token: token,
    ticket_number: ticket_number,
    table_type: table_type,
    vip: vip,
    status: QueueTicket::STATUS_WAITING,
    position: 0
  )

  position = calculate_position(ticket)
  ticket.update(position: position)

  status 201
  {
    ticket_token: ticket.ticket_token,
    ticket_number: ticket.ticket_number,
    table_type: ticket.table_type,
    vip: ticket.vip,
    position: position,
    created_at: ticket.created_at.iso8601
  }.to_json
end

get '/api/tickets/:token' do
  ticket = QueueTicket.where(ticket_token: params[:token]).first

  unless ticket
    status 404
    return { error: 'Ticket not found' }.to_json
  end

  position = calculate_position(ticket)
  ticket.update(position: position) if ticket.status == QueueTicket::STATUS_WAITING

  {
    ticket_token: ticket.ticket_token,
    ticket_number: ticket.ticket_number,
    table_type: ticket.table_type,
    vip: ticket.vip,
    status: ticket.status,
    position: position,
    waiting_ahead: position > 0 ? position - 1 : 0,
    created_at: ticket.created_at.iso8601,
    called_at: ticket.called_at&.iso8601,
    served_at: ticket.served_at&.iso8601
  }.to_json
end

post '/api/call-next' do
  params = JSON.parse(request.body.read) rescue {}
  table_type = params['table_type']

  unless [QueueTicket::TABLE_SMALL, QueueTicket::TABLE_LARGE].include?(table_type)
    status 400
    return { error: 'Invalid table type. Must be "small" or "large"' }.to_json
  end

  ticket = find_next_ticket(table_type)

  unless ticket
    status 404
    return { error: 'No waiting tickets for this table type' }.to_json
  end

  ticket.update(
    status: QueueTicket::STATUS_CALLED,
    called_at: Time.now
  )

  {
    ticket_token: ticket.ticket_token,
    ticket_number: ticket.ticket_number,
    table_type: ticket.table_type,
    vip: ticket.vip,
    status: ticket.status,
    called_at: ticket.called_at.iso8601
  }.to_json
end

post '/api/tickets/:token/serve' do
  ticket = QueueTicket.where(ticket_token: params[:token]).first

  unless ticket
    status 404
    return { error: 'Ticket not found' }.to_json
  end

  unless ticket.status == QueueTicket::STATUS_CALLED
    status 400
    return { error: 'Ticket must be called before serving' }.to_json
  end

  ticket.update(
    status: QueueTicket::STATUS_SERVED,
    served_at: Time.now
  )

  {
    ticket_token: ticket.ticket_token,
    ticket_number: ticket.ticket_number,
    table_type: ticket.table_type,
    status: ticket.status,
    served_at: ticket.served_at.iso8601
  }.to_json
end

post '/api/tickets/:token/miss' do
  ticket = QueueTicket.where(ticket_token: params[:token]).first

  unless ticket
    status 404
    return { error: 'Ticket not found' }.to_json
  end

  unless ticket.status == QueueTicket::STATUS_CALLED
    status 400
    return { error: 'Ticket must be called before marking as missed' }.to_json
  end

  new_miss_count = ticket.miss_count + 1

  if new_miss_count >= 3
    ticket.update(
      status: QueueTicket::STATUS_CANCELLED,
      miss_count: new_miss_count
    )
  else
    ticket.update(
      status: QueueTicket::STATUS_WAITING,
      miss_count: new_miss_count
    )
  end

  {
    ticket_token: ticket.ticket_token,
    ticket_number: ticket.ticket_number,
    status: ticket.status,
    miss_count: ticket.miss_count
  }.to_json
end

get '/api/queue/:table_type' do
  table_type = params[:table_type]

  unless [QueueTicket::TABLE_SMALL, QueueTicket::TABLE_LARGE].include?(table_type)
    status 400
    return { error: 'Invalid table type. Must be "small" or "large"' }.to_json
  end

  waiting_count = get_waiting_count(table_type)
  current_call = QueueTicket.where(
    table_type: table_type,
    status: QueueTicket::STATUS_CALLED
  ).order(Sequel.desc(:called_at)).first

  next_ticket = find_next_ticket(table_type)

  {
    table_type: table_type,
    waiting_count: waiting_count,
    current_call: current_call ? {
      ticket_number: current_call.ticket_number,
      called_at: current_call.called_at.iso8601
    } : nil,
    next_ticket: next_ticket ? {
      ticket_number: next_ticket.ticket_number,
      vip: next_ticket.vip
    } : nil
  }.to_json
end

get '/api/stats/daily' do
  today = Date.today
  start_of_day = Time.new(today.year, today.month, today.day, 0, 0, 0)
  end_of_day = start_of_day + 86400

  tickets_today = QueueTicket.where { created_at >= start_of_day }.where { created_at < end_of_day }.all

  hourly_stats = {}
  (0..23).each do |hour|
    hourly_stats[hour.to_s] = {
      small: 0,
      large: 0,
      vip: 0,
      total: 0
    }
  end

  table_type_stats = {
    small: { total: 0, waiting: 0, served: 0, cancelled: 0 },
    large: { total: 0, waiting: 0, served: 0, cancelled: 0 }
  }

  vip_stats = { total: 0, served: 0 }

  tickets_today.each do |ticket|
    hour = ticket.created_at.hour
    table_type = ticket.table_type.to_sym

    hourly_stats[hour.to_s][table_type] += 1
    hourly_stats[hour.to_s][:total] += 1
    hourly_stats[hour.to_s][:vip] += 1 if ticket.vip

    table_type_stats[table_type][:total] += 1
    table_type_stats[table_type][ticket.status.to_sym] += 1 if table_type_stats[table_type].key?(ticket.status.to_sym)

    if ticket.vip
      vip_stats[:total] += 1
      vip_stats[:served] += 1 if ticket.status == QueueTicket::STATUS_SERVED
    end
  end

  peak_hour = hourly_stats.max_by { |_, v| v[:total] }
  peak_hour = peak_hour ? { hour: peak_hour[0].to_i, count: peak_hour[1][:total] } : nil

  {
    date: today.iso8601,
    total_tickets: tickets_today.count,
    table_type_stats: table_type_stats,
    vip_stats: vip_stats,
    hourly_stats: hourly_stats,
    peak_hour: peak_hour,
    current_waiting: {
      small: get_waiting_count(QueueTicket::TABLE_SMALL),
      large: get_waiting_count(QueueTicket::TABLE_LARGE)
    }
  }.to_json
end

get '/api/stats/queue/:table_type' do
  table_type = params[:table_type]

  unless [QueueTicket::TABLE_SMALL, QueueTicket::TABLE_LARGE].include?(table_type)
    status 400
    return { error: 'Invalid table type. Must be "small" or "large"' }.to_json
  end

  waiting_tickets = QueueTicket.where(
    table_type: table_type,
    status: QueueTicket::STATUS_WAITING
  ).order(Sequel.desc(:vip), Sequel.asc(:id)).all

  queue = waiting_tickets.map.with_index do |ticket, idx|
    {
      position: idx + 1,
      ticket_number: ticket.ticket_number,
      vip: ticket.vip,
      wait_time: ((Time.now - ticket.created_at) / 60).round(1),
      created_at: ticket.created_at.iso8601
    }
  end

  {
    table_type: table_type,
    waiting_count: queue.count,
    queue: queue
  }.to_json
end

not_found do
  { error: 'Endpoint not found' }.to_json
end
