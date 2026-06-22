require 'sinatra'
require 'sinatra/json'
require 'sequel'
require 'json'
require 'securerandom'
require 'rack/cors'

use Rack::Cors do
  allow do
    origins '*'
    resource '*', headers: :any, methods: [:get, :post, :put, :options]
  end
end

DB = Sequel.sqlite('queue.db')

unless DB.table_exists?(:queue_items)
  DB.create_table :queue_items do
    primary_key :id
    String :queue_number, null: false
    String :table_type, null: false
    String :customer_token, null: false, unique: true
    TrueClass :vip, default: false
    String :status, default: 'waiting'
    Integer :priority, default: 0
    DateTime :created_at
    DateTime :called_at
    DateTime :completed_at
    index [:table_type, :status]
    index [:customer_token], unique: true
  end
else
  DB.alter_table :queue_items do
    add_column :priority, Integer, default: 0 unless DB[:queue_items].columns.include?(:priority)
    add_column :created_at, DateTime unless DB[:queue_items].columns.include?(:created_at)
    add_column :called_at, DateTime unless DB[:queue_items].columns.include?(:called_at)
    add_column :completed_at, DateTime unless DB[:queue_items].columns.include?(:completed_at)
  end
end

unless DB.table_exists?(:call_records)
  DB.create_table :call_records do
    primary_key :id
    Integer :queue_item_id
    String :table_type
    DateTime :called_at
  end
end

class QueueItem < Sequel::Model
  plugin :validation_helpers

  def validate
    super
    validates_includes %w[large small], :table_type
    validates_includes %w[waiting called completed cancelled], :status
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
end

class CallRecord < Sequel::Model
end

before do
  content_type :json
end

helpers do
  def parse_request_body
    return {} unless request.body.size > 0
    request.body.rewind
    JSON.parse(request.body.read) rescue {}
  end
end

post '/api/take_number' do
  params = parse_request_body
  table_type = params['table_type']
  vip = params['vip'] || false

  unless %w[large small].include?(table_type)
    status 400
    return json error: 'Invalid table_type, must be "large" or "small"'
  end

  customer_token = SecureRandom.uuid
  queue_number = QueueItem.generate_queue_number(table_type, vip)

  max_priority = QueueItem.where(table_type: table_type, vip: vip, status: 'waiting')
                          .max(:priority) || 0
  priority = vip ? max_priority + 1 : 0

  item = QueueItem.create(
    queue_number: queue_number,
    table_type: table_type,
    customer_token: customer_token,
    vip: vip,
    status: 'waiting',
    priority: priority,
    created_at: Time.now
  )

  ahead_count = QueueItem.count_ahead(customer_token)

  json(
    queue_number: item.queue_number,
    customer_token: item.customer_token,
    table_type: item.table_type,
    vip: item.vip,
    status: item.status,
    ahead_count: ahead_count,
    created_at: item.created_at.iso8601
  )
end

post '/api/call_next' do
  params = parse_request_body
  table_type = params['table_type']

  unless %w[large small].include?(table_type)
    status 400
    return json error: 'Invalid table_type, must be "large" or "small"'
  end

  next_item = QueueItem.next_waiting(table_type)

  unless next_item
    status 404
    return json message: 'No customers waiting in queue'
  end

  next_item.update(
    status: 'called',
    called_at: Time.now
  )

  CallRecord.create(
    queue_item_id: next_item.id,
    table_type: table_type,
    called_at: Time.now
  )

  json(
    queue_number: next_item.queue_number,
    table_type: next_item.table_type,
    vip: next_item.vip,
    called_at: next_item.called_at.iso8601,
    message: "Calling #{next_item.queue_number} to #{next_item.table_type == 'large' ? 'large' : 'small'} table"
  )
end

get '/api/queue_status/:customer_token' do
  customer_token = params[:customer_token]
  item = QueueItem.where(customer_token: customer_token).first

  unless item
    status 404
    return json error: 'Invalid customer token'
  end

  ahead_count = QueueItem.count_ahead(customer_token)

  json(
    queue_number: item.queue_number,
    table_type: item.table_type,
    vip: item.vip,
    status: item.status,
    ahead_count: ahead_count,
    created_at: item.created_at.iso8601,
    called_at: item.called_at&.iso8601,
    message: case item.status
             when 'waiting' then "You are #{ahead_count + 1} in the queue"
             when 'called' then 'Your turn! Please proceed to your table'
             when 'completed' then 'Your visit has been completed'
             when 'cancelled' then 'Your queue has been cancelled'
             end
  )
end

get '/api/stats/today' do
  today = Date.today
  start_of_day = today.to_time
  end_of_day = (today + 1).to_time

  items_today = QueueItem.where(Sequel[:created_at] >= start_of_day)
                         .where(Sequel[:created_at] < end_of_day)

  hourly_stats = (0..23).map do |hour|
    hour_start = start_of_day + hour * 3600
    hour_end = hour_start + 3600

    hour_items = items_today.where(Sequel[:created_at] >= hour_start)
                            .where(Sequel[:created_at] < hour_end)

    {
      hour: hour,
      time_range: "#{sprintf('%02d:00', hour)}-#{sprintf('%02d:00', hour + 1)}",
      total_customers: hour_items.count,
      large_table: hour_items.where(table_type: 'large').count,
      small_table: hour_items.where(table_type: 'small').count,
      vip_customers: hour_items.where(vip: true).count,
      avg_wait_time: calculate_avg_wait_time(hour_items)
    }
  end.select { |h| h[:total_customers] > 0 }

  peak_hour = hourly_stats.max_by { |h| h[:total_customers] }

  summary = {
    total_customers_today: items_today.count,
    large_table_count: items_today.where(table_type: 'large').count,
    small_table_count: items_today.where(table_type: 'small').count,
    vip_count: items_today.where(vip: true).count,
    currently_waiting: QueueItem.where(status: 'waiting').count,
    currently_called: QueueItem.where(status: 'called').count,
    completed_count: items_today.where(status: 'completed').count,
    peak_hour: peak_hour ? peak_hour[:time_range] : nil,
    peak_customers: peak_hour ? peak_hour[:total_customers] : 0
  }

  json(
    date: today.iso8601,
    summary: summary,
    hourly_stats: hourly_stats
  )
end

def calculate_avg_wait_time(items)
  called_items = items.where(status: %w[called completed]).exclude(called_at: nil).all
  return 0 if called_items.empty?

  total_wait = called_items.sum do |item|
    (item[:called_at].to_time - item[:created_at].to_time).to_i
  end

  (total_wait / called_items.size / 60).to_i
end

get '/api/queue/list' do
  table_type = params['table_type']
  status = params['status'] || 'waiting'

  items = QueueItem
  items = items.where(table_type: table_type) if table_type && %w[large small].include?(table_type)
  items = items.where(status: status) if status && %w[waiting called completed cancelled].include?(status)

  result = items.order(Sequel.desc(:vip), Sequel.desc(:priority), Sequel.asc(:created_at))
                .map do |item|
    ahead_count = item.status == 'waiting' ? QueueItem.count_ahead(item.customer_token) : 0
    {
      queue_number: item.queue_number,
      table_type: item.table_type,
      vip: item.vip,
      status: item.status,
      ahead_count: ahead_count,
      created_at: item.created_at.iso8601,
      called_at: item.called_at&.iso8601
    }
  end

  json queue: result, count: result.count
end

put '/api/queue/:customer_token/complete' do
  item = QueueItem.where(customer_token: params[:customer_token]).first

  unless item
    status 404
    return json error: 'Invalid customer token'
  end

  item.update(
    status: 'completed',
    completed_at: Time.now
  )

  json message: 'Queue completed successfully', status: item.status
end

put '/api/queue/:customer_token/cancel' do
  item = QueueItem.where(customer_token: params[:customer_token]).first

  unless item
    status 404
    return json error: 'Invalid customer token'
  end

  item.update(status: 'cancelled')

  json message: 'Queue cancelled successfully', status: item.status
end

get '/health' do
  json status: 'ok', time: Time.now.iso8601
end
