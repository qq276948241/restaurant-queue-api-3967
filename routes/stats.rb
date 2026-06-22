require 'sinatra'

helpers ApiHelper

get '/api/stats/today' do
  today = Date.today
  start_of_day = today.to_time
  end_of_day = (today + 1).to_time

  items_today = QueueItem.where(Sequel[:created_at] >= start_of_day)
                         .where(Sequel[:created_at] < end_of_day)

  hourly_stats = (0..23).map do |hour|
    hour_start = start_of_day + hour * 3600
    hour_end = hour_start + 3600

    hour_items = items_today.where(Sequel[:created_at] >= hour_start)
                            .where(Sequel[:created_at] < hour_end)

    {
      hour: hour,
      time_range: "#{sprintf('%02d:00', hour)}-#{sprintf('%02d:00', hour + 1)}",
      total_customers: hour_items.count,
      large_table: hour_items.where(table_type: 'large').count,
      small_table: hour_items.where(table_type: 'small').count,
      vip_customers: hour_items.where(vip: true).count,
      avg_wait_time: calculate_avg_wait_time(hour_items)
    }
  end.select { |h| h[:total_customers] > 0 }

  peak_hour = hourly_stats.max_by { |h| h[:total_customers] }

  summary = {
    total_customers_today: items_today.count,
    large_table_count: items_today.where(table_type: 'large').count,
    small_table_count: items_today.where(table_type: 'small').count,
    vip_count: items_today.where(vip: true).count,
    currently_waiting: QueueItem.where(status: 'waiting').count,
    currently_called: QueueItem.where(status: 'called').count,
    expired_count: items_today.where(status: 'expired').count,
    completed_count: items_today.where(status: 'completed').count,
    peak_hour: peak_hour ? peak_hour[:time_range] : nil,
    peak_customers: peak_hour ? peak_hour[:total_customers] : 0
  }

  json(
    date: today.iso8601,
    summary: summary,
    hourly_stats: hourly_stats
  )
end
