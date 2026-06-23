require 'minitest/autorun'
require 'rack/test'
require 'json'
require 'sequel'

ENV['RACK_ENV'] = 'test'

require_relative 'app'

class QueueApiTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def setup
    DB[:queue_tickets].delete
    DB[:daily_counters].delete
  end

  def test_create_small_table_ticket
    post '/api/tickets', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'

    assert_equal 201, last_response.status
    response = JSON.parse(last_response.body)
    assert_equal 'small', response['table_type']
    assert_equal false, response['vip']
    assert_equal 1, response['ticket_number']
    assert response['ticket_token']
  end

  def test_create_large_table_ticket
    post '/api/tickets', { table_type: 'large' }.to_json, 'CONTENT_TYPE' => 'application/json'

    assert_equal 201, last_response.status
    response = JSON.parse(last_response.body)
    assert_equal 'large', response['table_type']
    assert_equal 1, response['ticket_number']
  end

  def test_create_vip_ticket
    post '/api/tickets', { table_type: 'small', vip: true }.to_json, 'CONTENT_TYPE' => 'application/json'

    assert_equal 201, last_response.status
    response = JSON.parse(last_response.body)
    assert_equal true, response['vip']
  end

  def test_invalid_table_type
    post '/api/tickets', { table_type: 'invalid' }.to_json, 'CONTENT_TYPE' => 'application/json'

    assert_equal 400, last_response.status
    response = JSON.parse(last_response.body)
    assert response['error']
  end

  def test_get_ticket_status
    post '/api/tickets', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
    ticket = JSON.parse(last_response.body)

    get "/api/tickets/#{ticket['ticket_token']}"

    assert_equal 200, last_response.status
    response = JSON.parse(last_response.body)
    assert_equal 'waiting', response['status']
    assert response.key?('waiting_ahead')
  end

  def test_get_nonexistent_ticket
    get '/api/tickets/nonexistent'

    assert_equal 404, last_response.status
  end

  def test_call_next_ticket
    post '/api/tickets', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'

    post '/api/call-next', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'

    assert_equal 200, last_response.status
    response = JSON.parse(last_response.body)
    assert_equal 'called', response['status']
    assert response['called_at']
  end

  def test_call_next_no_tickets
    post '/api/call-next', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'

    assert_equal 404, last_response.status
  end

  def test_vip_priority
    post '/api/tickets', { table_type: 'small', vip: false }.to_json, 'CONTENT_TYPE' => 'application/json'
    regular = JSON.parse(last_response.body)

    post '/api/tickets', { table_type: 'small', vip: true }.to_json, 'CONTENT_TYPE' => 'application/json'
    vip = JSON.parse(last_response.body)

    post '/api/call-next', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
    called = JSON.parse(last_response.body)

    assert_equal vip['ticket_number'], called['ticket_number']
    assert_equal true, called['vip']
  end

  def test_vip_position_calculation
    post '/api/tickets', { table_type: 'small', vip: false }.to_json, 'CONTENT_TYPE' => 'application/json'
    post '/api/tickets', { table_type: 'small', vip: false }.to_json, 'CONTENT_TYPE' => 'application/json'

    post '/api/tickets', { table_type: 'small', vip: true }.to_json, 'CONTENT_TYPE' => 'application/json'
    vip = JSON.parse(last_response.body)

    get "/api/tickets/#{vip['ticket_token']}"
    status = JSON.parse(last_response.body)

    assert_equal 1, status['position']
    assert_equal 0, status['waiting_ahead']
  end

  def test_serve_ticket
    post '/api/tickets', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
    ticket = JSON.parse(last_response.body)

    post '/api/call-next', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'

    post "/api/tickets/#{ticket['ticket_token']}/serve"

    assert_equal 200, last_response.status
    response = JSON.parse(last_response.body)
    assert_equal 'served', response['status']
    assert response['served_at']
  end

  def test_miss_ticket
    post '/api/tickets', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
    ticket = JSON.parse(last_response.body)

    post '/api/call-next', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'

    post "/api/tickets/#{ticket['ticket_token']}/miss"

    assert_equal 200, last_response.status
    response = JSON.parse(last_response.body)
    assert_equal 1, response['miss_count']
  end

  def test_miss_three_times_cancels
    post '/api/tickets', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
    ticket = JSON.parse(last_response.body)

    3.times do
      post '/api/call-next', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
      post "/api/tickets/#{ticket['ticket_token']}/miss"
    end

    response = JSON.parse(last_response.body)
    assert_equal 'cancelled', response['status']
  end

  def test_queue_status
    post '/api/tickets', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
    post '/api/tickets', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'

    get '/api/queue/small'

    assert_equal 200, last_response.status
    response = JSON.parse(last_response.body)
    assert_equal 2, response['waiting_count']
  end

  def test_daily_stats
    post '/api/tickets', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
    post '/api/tickets', { table_type: 'large' }.to_json, 'CONTENT_TYPE' => 'application/json'
    post '/api/tickets', { table_type: 'small', vip: true }.to_json, 'CONTENT_TYPE' => 'application/json'

    get '/api/stats/daily'

    assert_equal 200, last_response.status
    response = JSON.parse(last_response.body)
    assert_equal 3, response['total_tickets']
    assert response['hourly_stats']
    assert response['peak_hour']
    assert response['table_type_stats']
  end

  def test_queue_stats
    post '/api/tickets', { table_type: 'small', vip: false }.to_json, 'CONTENT_TYPE' => 'application/json'
    post '/api/tickets', { table_type: 'small', vip: true }.to_json, 'CONTENT_TYPE' => 'application/json'
    post '/api/tickets', { table_type: 'small', vip: false }.to_json, 'CONTENT_TYPE' => 'application/json'

    get '/api/stats/queue/small'

    assert_equal 200, last_response.status
    response = JSON.parse(last_response.body)
    assert_equal 3, response['waiting_count']
    assert_equal true, response['queue'][0]['vip']
    assert_equal false, response['queue'][1]['vip']
  end

  def test_waiting_ahead_calculation
    post '/api/tickets', { table_type: 'small', vip: false }.to_json, 'CONTENT_TYPE' => 'application/json'
    ticket1 = JSON.parse(last_response.body)

    post '/api/tickets', { table_type: 'small', vip: false }.to_json, 'CONTENT_TYPE' => 'application/json'
    ticket2 = JSON.parse(last_response.body)

    get "/api/tickets/#{ticket2['ticket_token']}"
    status = JSON.parse(last_response.body)

    assert_equal 2, status['position']
    assert_equal 1, status['waiting_ahead']
  end

  def test_daily_counter_resets
    today = Date.today
    DailyCounter.create(table_type: 'small', date: today - 1, counter: 100)

    post '/api/tickets', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
    ticket = JSON.parse(last_response.body)

    assert_equal 1, ticket['ticket_number']
  end
end
