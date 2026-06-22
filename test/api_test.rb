require 'minitest/autorun'
require 'rack/test'
require_relative '../app'

class APITest < Minitest::Test
  include Rack::Test::Methods

  def app
    RestaurantQueue::API
  end

  def setup
    RestaurantQueue::API.set :queue_manager, QueueManager.new
  end

  def test_create_small_table_ticket
    post '/tickets', { table_type: 'small', people_count: 2 }.to_json, 'CONTENT_TYPE' => 'application/json'
    assert_equal 201, last_response.status

    data = JSON.parse(last_response.body)
    assert_match(/^S\d{4}$/, data['number'])
    assert_equal 'small', data['table_type']
    assert_equal 'waiting', data['status']
    assert_equal 0, data['position']
    assert_equal false, data['vip']
  end

  def test_create_large_table_ticket
    post '/tickets', { table_type: 'large', people_count: 6 }.to_json, 'CONTENT_TYPE' => 'application/json'
    assert_equal 201, last_response.status

    data = JSON.parse(last_response.body)
    assert_match(/^L\d{4}$/, data['number'])
    assert_equal 'large', data['table_type']
  end

  def test_create_vip_ticket
    post '/tickets', { table_type: 'small', people_count: 2, vip: true }.to_json, 'CONTENT_TYPE' => 'application/json'
    assert_equal 201, last_response.status

    data = JSON.parse(last_response.body)
    assert_equal true, data['vip']
  end

  def test_invalid_table_type
    post '/tickets', { table_type: 'medium' }.to_json, 'CONTENT_TYPE' => 'application/json'
    assert_equal 400, last_response.status
  end

  def test_get_ticket
    post '/tickets', { table_type: 'small', people_count: 2 }.to_json, 'CONTENT_TYPE' => 'application/json'
    ticket_id = JSON.parse(last_response.body)['id']

    get "/tickets/#{ticket_id}"
    assert_equal 200, last_response.status

    data = JSON.parse(last_response.body)
    assert_equal ticket_id, data['id']
    assert_equal 'small', data['table_type']
  end

  def test_get_nonexistent_ticket
    get '/tickets/nonexistent'
    assert_equal 404, last_response.status
  end

  def test_call_next
    post '/tickets', { table_type: 'small', people_count: 2 }.to_json, 'CONTENT_TYPE' => 'application/json'

    post '/call/next', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status

    data = JSON.parse(last_response.body)
    assert_equal 'called', data['status']
    assert_match(/^S\d{4}$/, data['number'])
    refute_nil data['called_at']
  end

  def test_call_next_empty_queue
    post '/call/next', { table_type: 'large' }.to_json, 'CONTENT_TYPE' => 'application/json'
    assert_equal 404, last_response.status
  end

  def test_vip_called_before_normal
    post '/tickets', { table_type: 'small', people_count: 2 }.to_json, 'CONTENT_TYPE' => 'application/json'
    normal_number = JSON.parse(last_response.body)['number']

    post '/tickets', { table_type: 'small', people_count: 2, vip: true }.to_json, 'CONTENT_TYPE' => 'application/json'
    vip_number = JSON.parse(last_response.body)['number']

    post '/call/next', { table_type: 'small' }.to_json, 'CONTENT_TYPE' => 'application/json'
    first_called = JSON.parse(last_response.body)['number']

    assert_equal vip_number, first_called
  end

  def test_position_of_ticket
    post '/tickets', { table_type: 'small', people_count: 2 }.to_json, 'CONTENT_TYPE' => 'application/json'
    first_id = JSON.parse(last_response.body)['id']

    post '/tickets', { table_type: 'small', people_count: 2 }.to_json, 'CONTENT_TYPE' => 'application/json'
    second_id = JSON.parse(last_response.body)['id']

    get "/tickets/#{second_id}"
    position = JSON.parse(last_response.body)['position']
    assert_equal 1, position
  end

  def test_daily_stats
    post '/tickets', { table_type: 'small', people_count: 2 }.to_json, 'CONTENT_TYPE' => 'application/json'
    post '/tickets', { table_type: 'large', people_count: 6 }.to_json, 'CONTENT_TYPE' => 'application/json'
    post '/tickets', { table_type: 'small', people_count: 3, vip: true }.to_json, 'CONTENT_TYPE' => 'application/json'

    get '/stats/today'
    assert_equal 200, last_response.status

    data = JSON.parse(last_response.body)
    assert_equal 3, data['total_tickets']
    assert_equal 2, data['total_small']
    assert_equal 1, data['total_large']
    assert_equal 1, data['total_vip']
    assert_equal 3, data['currently_waiting']
    assert_includes data['hourly'], Time.now.strftime('%H:00')
  end

  def test_queue_status
    post '/tickets', { table_type: 'small', people_count: 2 }.to_json, 'CONTENT_TYPE' => 'application/json'
    post '/tickets', { table_type: 'small', people_count: 2, vip: true }.to_json, 'CONTENT_TYPE' => 'application/json'
    post '/tickets', { table_type: 'large', people_count: 6 }.to_json, 'CONTENT_TYPE' => 'application/json'

    get '/queues'
    data = JSON.parse(last_response.body)

    assert_equal 2, data['small']['waiting']
    assert_equal 1, data['small']['vip_waiting']
    assert_equal 1, data['large']['waiting']
    assert_equal 0, data['large']['vip_waiting']
  end
end
