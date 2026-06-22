require 'sinatra'

helpers ApiHelper

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

put '/api/queue/:customer_token/requeue' do
  item = QueueItem.where(customer_token: params[:customer_token]).first

  unless item
    status 404
    return json error: 'Invalid customer token'
  end

  unless item.status == 'expired'
    status 400
    return json error: 'Only expired (no-show) customers can requeue'
  end

  QueueItem.where(table_type: item.table_type, status: 'waiting')
           .max(:priority) || 0

  item.update(
    status: 'waiting',
    vip: false,
    priority: 0,
    called_at: nil,
    created_at: Time.now
  )

  ahead_count = QueueItem.count_ahead(item.customer_token)
  estimated_wait = QueueItem.estimate_wait_time(item.table_type, ahead_count)

  json(
    message: 'Requeued successfully at the end of the line',
    queue_number: item.queue_number,
    status: item.status,
    ahead_count: ahead_count,
    estimated_wait_minutes: estimated_wait
  )
end
