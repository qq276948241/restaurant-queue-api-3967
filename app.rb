# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/json'
require 'sequel'
require 'json'
require_relative 'queue_service'

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

  def parse_body
    body = request.body.read
    JSON.parse(body) rescue {}
  end

  def error_json(message, status_code = 400)
    status status_code
    json error: message
  end

  def validate_table_type(type)
    unless QueueService.valid_table_type?(type)
      return error_json 'invalid table_type, must be small or large'
    end
    nil
  end

  post '/api/queue/take' do
    params = parse_body
    table_type = params['table_type']
    vip = params['vip'] || false

    err = validate_table_type(table_type)
    return err if err

    ticket = QueueService.take_number(table_type, vip: vip)

    status 201
    json ticket
  end

  post '/api/queue/vip_insert' do
    params = parse_body
    table_type = params['table_type']

    err = validate_table_type(table_type)
    return err if err

    ticket = QueueService.vip_insert(table_type)

    status 201
    json ticket
  end

  post '/api/queue/call_next' do
    params = parse_body
    table_type = params['table_type']

    err = validate_table_type(table_type)
    return err if err

    ticket = QueueService.call_next(table_type)

    unless ticket
      return error_json 'no one waiting in queue', 404
    end

    json ticket
  end

  post '/api/queue/confirm_served' do
    params = parse_body
    token = params['ticket_token']

    ticket = QueueService.confirm_served(token)

    unless ticket
      return error_json 'no called ticket found with this token', 404
    end

    json ticket
  end

  post '/api/queue/miss' do
    params = parse_body
    token = params['ticket_token']

    ticket = QueueService.handle_miss(token)

    unless ticket
      return error_json 'no called ticket found with this token', 404
    end

    json ticket
  end

  post '/api/queue/cancel' do
    params = parse_body
    token = params['ticket_token']

    ticket = QueueService.cancel(token)

    unless ticket
      return error_json 'no active ticket found with this token', 404
    end

    json ticket
  end

  get '/api/queue/status/:ticket_token' do
    ticket = QueueService.status(params[:ticket_token])

    unless ticket
      return error_json 'ticket not found', 404
    end

    json ticket
  end

  get '/api/queue/current' do
    table_type = params['table_type']
    tickets = QueueService.current_queue(table_type: table_type)
    json tickets: tickets
  end

  get '/api/queue/summary' do
    json QueueService.summary
  end

  get '/api/queue/stats' do
    date_str = params['date']
    target_date = date_str ? Date.parse(date_str) : Date.today
    json QueueService.stats(target_date)
  end

  run! if app_file == $0
end
