require 'sinatra'
require 'sinatra/json'
require 'json'
require 'time'
require_relative 'lib/queue_manager'
require_relative 'lib/ticket'

module RestaurantQueue
  class API < Sinatra::Base
    helpers Sinatra::JSON

    set :queue_manager, QueueManager.new

    before do
      content_type :json
    end

    post '/tickets' do
      data = JSON.parse(request.body.read)
      table_type = data['table_type']
      vip = data['vip'] || false
      people_count = data['people_count']

      unless %w[small large].include?(table_type)
        status 400
        return json(error: 'Invalid table_type, must be small or large')
      end

      ticket = settings.queue_manager.create_ticket(table_type, vip, people_count)
      status 201
      json(
        id: ticket.id,
        number: ticket.number,
        table_type: ticket.table_type,
        vip: ticket.vip,
        people_count: ticket.people_count,
        status: ticket.status,
        created_at: ticket.created_at.iso8601,
        position: settings.queue_manager.position_of(ticket.id)
      )
    end

    get '/tickets/:id' do |id|
      ticket = settings.queue_manager.find_ticket(id)

      unless ticket
        status 404
        return json(error: 'Ticket not found')
      end

      json(
        id: ticket.id,
        number: ticket.number,
        table_type: ticket.table_type,
        vip: ticket.vip,
        people_count: ticket.people_count,
        status: ticket.status,
        created_at: ticket.created_at.iso8601,
        called_at: ticket.called_at&.iso8601,
        position: settings.queue_manager.position_of(id)
      )
    end

    post '/call/next' do
      data = JSON.parse(request.body.read) rescue {}
      table_type = data['table_type']

      unless %w[small large].include?(table_type)
        status 400
        return json(error: 'Invalid table_type, must be small or large')
      end

      ticket = settings.queue_manager.call_next(table_type)

      unless ticket
        status 404
        return json(error: 'No waiting tickets for this table type')
      end

      json(
        id: ticket.id,
        number: ticket.number,
        table_type: ticket.table_type,
        vip: ticket.vip,
        people_count: ticket.people_count,
        status: ticket.status,
        created_at: ticket.created_at.iso8601,
        called_at: ticket.called_at.iso8601
      )
    end

    get '/stats/today' do
      stats = settings.queue_manager.daily_stats
      json(stats)
    end

    get '/queues' do
      queues = settings.queue_manager.queue_status
      json(queues)
    end
  end
end
