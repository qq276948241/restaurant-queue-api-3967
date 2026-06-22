require 'sinatra'

helpers ApiHelper

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
  estimated_wait = QueueItem.estimate_wait_time(table_type, ahead_count)

  json(
    queue_number: item.queue_number,
    customer_token: item.customer_token,
    table_type: item.table_type,
    vip: item.vip,
    status: item.status,
    ahead_count: ahead_count,
    estimated_wait_minutes: estimated_wait,
    created_at: item.created_at.iso8601
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
  estimated_wait = item.status == 'waiting' ? QueueItem.estimate_wait_time(item.table_type, ahead_count) : 0

  json(
    queue_number: item.queue_number,
    table_type: item.table_type,
    vip: item.vip,
    status: item.status,
    ahead_count: ahead_count,
    estimated_wait_minutes: estimated_wait,
    created_at: item.created_at.iso8601,
    called_at: item.called_at&.iso8601,
    message: case item.status
             when 'waiting' then "You are #{ahead_count + 1} in the queue"
             when 'called' then 'Your turn! Please proceed to your table'
             when 'completed' then 'Your visit has been completed'
             when 'cancelled' then 'Your queue has been cancelled'
             when 'expired' then 'Your queue has expired (no-show). You can requeue at the end of the line.'
             end
  )
end

get '/api/queue/list' do
  table_type = params['table_type']
  status = params['status'] || 'waiting'

  items = QueueItem
  items = items.where(table_type: table_type) if table_type && %w[large small].include?(table_type)
  items = items.where(status: status) if status && %w[waiting called completed cancelled expired].include?(status)

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
