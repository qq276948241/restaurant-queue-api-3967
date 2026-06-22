module ApiHelper
  def parse_request_body
    return {} unless request.body.size > 0
    request.body.rewind
    JSON.parse(request.body.read) rescue {}
  end

  def calculate_avg_wait_time(items)
    called_items = items.where(status: %w[called completed]).exclude(called_at: nil).all
    return 0 if called_items.empty?

    total_wait = called_items.sum do |item|
      (item[:called_at].to_time - item[:created_at].to_time).to_i
    end

    (total_wait / called_items.size / 60).to_i
  end
end
