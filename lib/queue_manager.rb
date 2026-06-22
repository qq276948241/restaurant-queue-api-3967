require_relative 'ticket'

class QueueManager
  def initialize
    @small_queue = []
    @large_queue = []
    @all_tickets = {}
    @small_counter = 0
    @large_counter = 0
  end

  def create_ticket(table_type, vip = false, people_count = nil)
    if table_type == 'small'
      @small_counter += 1
      number = "S#{format('%04d', @small_counter)}"
    else
      @large_counter += 1
      number = "L#{format('%04d', @large_counter)}"
    end

    ticket = Ticket.new(number, table_type, vip, people_count)
    queue = queue_for(table_type)

    if vip
      insert_vip(queue, ticket)
    else
      queue << ticket
    end

    @all_tickets[ticket.id] = ticket
    ticket
  end

  def call_next(table_type)
    queue = queue_for(table_type)
    ticket = queue.shift
    ticket&.call!
    ticket
  end

  def find_ticket(id)
    @all_tickets[id]
  end

  def position_of(ticket_id)
    ticket = @all_tickets[ticket_id]
    return nil unless ticket&.waiting?

    queue = queue_for(ticket.table_type)
    index = queue.index { |t| t.id == ticket_id }
    index
  end

  def queue_status
    {
      small: {
        waiting: @small_queue.count { |t| t.waiting? },
        vip_waiting: @small_queue.count { |t| t.waiting? && t.vip }
      },
      large: {
        waiting: @large_queue.count { |t| t.waiting? },
        vip_waiting: @large_queue.count { |t| t.waiting? && t.vip }
      }
    }
  end

  def daily_stats
    today = Date.today
    today_tickets = @all_tickets.values.select { |t| t.created_at.to_date == today }

    hourly = {}
    (0..23).each do |hour|
      key = format('%02d:00', hour)
      hour_tickets = today_tickets.select { |t| t.created_at.hour == hour }
      hourly[key] = {
        total: hour_tickets.count,
        small: hour_tickets.count { |t| t.table_type == 'small' },
        large: hour_tickets.count { |t| t.table_type == 'large' },
        vip: hour_tickets.count { |t| t.vip },
        called: hour_tickets.count { |t| t.called? }
      }
    end

    peak_hour = hourly.max_by { |_, v| v[:total] }

    {
      date: today.iso8601,
      total_tickets: today_tickets.count,
      total_small: today_tickets.count { |t| t.table_type == 'small' },
      total_large: today_tickets.count { |t| t.table_type == 'large' },
      total_vip: today_tickets.count { |t| t.vip },
      total_called: today_tickets.count { |t| t.called? },
      currently_waiting: today_tickets.count { |t| t.waiting? },
      peak_hour: peak_hour ? peak_hour[0] : nil,
      peak_hour_count: peak_hour ? peak_hour[1][:total] : 0,
      hourly: hourly
    }
  end

  private

  def queue_for(table_type)
    table_type == 'small' ? @small_queue : @large_queue
  end

  def insert_vip(queue, ticket)
    last_vip_index = queue.rindex { |t| t.vip }
    if last_vip_index
      queue.insert(last_vip_index + 1, ticket)
    else
      queue.unshift(ticket)
    end
  end
end
