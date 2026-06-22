require 'sinatra'
require 'sinatra/json'
require 'json'
require_relative 'queue_service'

set :port, 4567
set :bind, '0.0.0.0'

before do
  content_type :json
end

def validate_table_type!
  unless QueueService.valid_table_type?(params[:table_type])
    status 400
    return json error: 'Invalid table_type, must be "small" or "large"'
  end
  nil
end

def parse_bool(val)
  val == 'true' || val == true
end

post '/api/tickets' do
  table_type = params[:table_type]
  err = validate_table_type!
  return err if err

  is_vip = parse_bool(params[:is_vip])
  ticket = QueueService.create_ticket(table_type, is_vip)

  status 201
  json QueueService.serialize_ticket(ticket)
end

get '/api/tickets/:token' do
  ticket = QueueService.find_ticket_by_token(params[:token])

  unless ticket
    status 404
    return json error: 'Ticket not found'
  end

  json QueueService.serialize_ticket(ticket)
end

post '/api/tickets/:token/cancel' do
  ticket = QueueService.find_ticket_by_token(params[:token])

  unless ticket
    status 404
    return json error: 'Ticket not found'
  end

  unless QueueService.can_cancel?(ticket)
    status 400
    return json error: "Cannot cancel ticket with status: #{ticket.status}"
  end

  QueueService.cancel_ticket(ticket)
  json QueueService.serialize_cancel_result(ticket)
end

post '/api/kitchen/call' do
  err = validate_table_type!
  return err if err

  ticket = QueueService.call_next(params[:table_type])

  unless ticket
    status 404
    return json error: 'No waiting tickets'
  end

  json QueueService.serialize_call_result(ticket)
end

post '/api/kitchen/complete' do
  ticket = QueueService.find_ticket_by_no(params[:ticket_no])

  unless ticket
    status 404
    return json error: 'Ticket not found'
  end

  unless QueueService.can_complete?(ticket)
    status 400
    return json error: "Cannot complete ticket with status: #{ticket.status}"
  end

  QueueService.complete_ticket(ticket)
  json QueueService.serialize_complete_result(ticket)
end

get '/api/queue/:table_type' do
  err = validate_table_type!
  return err if err

  table_type = params[:table_type]
  json(
    table_type: table_type,
    waiting_count: QueueService.waiting_count(table_type),
    waiting_tickets: QueueService.queue_list(table_type)
  )
end

get '/api/stats/daily' do
  date = params[:date] ? Date.parse(params[:date]) : Date.today
  json QueueService.daily_stats(date)
end

get '/api/health' do
  json status: 'ok', time: Time.now.iso8601
end
