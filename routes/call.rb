require 'sinatra'

helpers ApiHelper

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
