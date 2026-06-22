require 'sinatra'

helpers ApiHelper

post '/api/test/simulate_timeout' do
  params = parse_request_body
  item = QueueItem.where(customer_token: params['customer_token']).first

  unless item
    status 404
    return json error: 'Invalid customer token'
  end

  unless item.status == 'called'
    status 400
    return json error: 'Customer is not in called status'
  end

  item.update(called_at: Time.now - 240)

  QueueItem.expire_timeout!

  json message: 'Simulated timeout: called_at set to 4 minutes ago, expired check triggered', status: item.reload.status
end
