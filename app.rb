require 'sinatra'
require 'sinatra/json'
require 'sqlite3'
require 'json'
require 'securerandom'
require 'time'

DB_PATH = File.join(__dir__, 'queue.db')

TABLE_TYPES = {
  'small' => { name: '小桌', seats: '1-4人' },
  'large' => { name: '大桌', seats: '5人以上' }
}.freeze

QUEUE_STATUS = {
  waiting: 'waiting',
  called: 'called',
  completed: 'completed',
  cancelled: 'cancelled'
}.freeze

AVG_WAIT_MINUTES_PER_TABLE = 15

def init_db
  db = SQLite3::Database.new(DB_PATH)

  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS queue_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      token TEXT UNIQUE NOT NULL,
      table_type TEXT NOT NULL,
      queue_number TEXT NOT NULL,
      is_vip INTEGER DEFAULT 0,
      status TEXT DEFAULT 'waiting',
      people_count INTEGER DEFAULT 1,
      called_at DATETIME,
      completed_at DATETIME,
      created_at DATETIME DEFAULT (datetime('now', 'localtime'))
    )
  SQL

  db.execute <<-SQL
    CREATE INDEX IF NOT EXISTS idx_queue_status ON queue_items(status)
  SQL

  db.execute <<-SQL
    CREATE INDEX IF NOT EXISTS idx_queue_type ON queue_items(table_type)
  SQL

  db.execute <<-SQL
    CREATE INDEX IF NOT EXISTS idx_queue_created ON queue_items(created_at)
  SQL

  db
end

def get_db
  @db ||= init_db
end

def generate_token
  loop do
    token = SecureRandom.alphanumeric(8).upcase
    result = get_db.execute('SELECT 1 FROM queue_items WHERE token = ?', token)
    break token if result.empty?
  end
end

def get_daily_queue_number(table_type, is_vip)
  today = Date.today.iso8601
  prefix = is_vip == 1 ? 'V' : (table_type == 'large' ? 'L' : 'S')
  date_start = "#{today} 00:00:00"
  date_end = "#{today} 23:59:59"

  result = get_db.execute(<<-SQL, table_type, is_vip, date_start, date_end)
    SELECT queue_number
    FROM queue_items
    WHERE table_type = ? AND is_vip = ?
      AND datetime(created_at, 'localtime') BETWEEN ? AND ?
    ORDER BY id DESC
    LIMIT 1
  SQL

  last_num = result.flatten.first
  if last_num
    seq = last_num[1..-1].to_i + 1
  else
    seq = 1
  end
  "#{prefix}#{seq.to_s.rjust(3, '0')}"
end

def count_ahead(token)
  item = get_db.execute('SELECT * FROM queue_items WHERE token = ?', token).first
  return nil unless item

  id, _token, table_type, queue_number, is_vip, status, _people = item

  return 0 if status != QUEUE_STATUS[:waiting]

  vip_ahead = get_db.execute(<<-SQL, table_type, QUEUE_STATUS[:waiting], id).flatten.first
    SELECT COUNT(*) FROM queue_items
    WHERE table_type = ? AND status = ? AND is_vip = 1 AND id < ?
  SQL

  normal_ahead = get_db.execute(<<-SQL, table_type, QUEUE_STATUS[:waiting], id).flatten.first
    SELECT COUNT(*) FROM queue_items
    WHERE table_type = ? AND status = ? AND is_vip = 0 AND id < ?
  SQL

  if is_vip == 1
    vip_ahead
  else
    vip_ahead + normal_ahead
  end
end

def estimate_wait_minutes(ahead_count)
  ahead_count * AVG_WAIT_MINUTES_PER_TABLE
end

def format_wait_time(minutes)
  if minutes == 0
    '即将叫号'
  elsif minutes < 60
    "约#{minutes}分钟"
  else
    hours = minutes / 60
    mins = minutes % 60
    mins == 0 ? "约#{hours}小时" : "约#{hours}小时#{mins}分钟"
  end
end

def get_next_customer(table_type)
  vip_customer = get_db.execute(<<-SQL, table_type, QUEUE_STATUS[:waiting]).first
    SELECT * FROM queue_items
    WHERE table_type = ? AND status = ? AND is_vip = 1
    ORDER BY id ASC
    LIMIT 1
  SQL

  return vip_customer if vip_customer

  get_db.execute(<<-SQL, table_type, QUEUE_STATUS[:waiting]).first
    SELECT * FROM queue_items
    WHERE table_type = ? AND status = ?
    ORDER BY id ASC
    LIMIT 1
  SQL
end

def build_queue_item_hash(row)
  return nil unless row
  {
    id: row[0],
    token: row[1],
    table_type: row[2],
    queue_number: row[3],
    is_vip: row[4] == 1,
    status: row[5],
    people_count: row[6],
    called_at: row[7],
    completed_at: row[8],
    created_at: row[9],
    table_type_name: TABLE_TYPES[row[2]]&.dig(:name),
    seats: TABLE_TYPES[row[2]]&.dig(:seats)
  }
end

def parse_request_body
  request.body.rewind
  JSON.parse(request.body.read) rescue {}
end

before do
  content_type :json
  headers 'Access-Control-Allow-Origin' => '*',
          'Access-Control-Allow-Methods' => ['OPTIONS', 'GET', 'POST', 'PUT'],
          'Access-Control-Allow-Headers' => 'Content-Type'
end

options '*' do
  200
end

get '/api/health' do
  json status: 'ok', time: Time.now.iso8601
end

post '/api/take-number' do
  params = parse_request_body

  table_type = params['table_type'].to_s
  people_count = params['people_count'].to_i
  is_vip = params['is_vip'] ? 1 : 0

  unless TABLE_TYPES.key?(table_type)
    status 400
    return json error: '无效的桌型，只能是 small 或 large'
  end

  if people_count < 1
    status 400
    return json error: '用餐人数至少为1人'
  end

  token = generate_token
  queue_number = get_daily_queue_number(table_type, is_vip)

  get_db.execute(<<-SQL, token, table_type, queue_number, is_vip, people_count)
    INSERT INTO queue_items (token, table_type, queue_number, is_vip, people_count)
    VALUES (?, ?, ?, ?, ?)
  SQL

  id = get_db.last_insert_row_id
  row = get_db.execute('SELECT * FROM queue_items WHERE id = ?', id).first
  item = build_queue_item_hash(row)
  ahead = count_ahead(token)
  item[:ahead_count] = ahead
  wait_minutes = estimate_wait_minutes(ahead)
  item[:estimated_wait_minutes] = wait_minutes
  item[:estimated_wait_text] = format_wait_time(wait_minutes)

  status 201
  json item
end

get '/api/queue-status/:token' do
  token = params['token'].to_s.upcase

  row = get_db.execute('SELECT * FROM queue_items WHERE token = ?', token).first

  unless row
    status 404
    return json error: '取号凭证不存在'
  end

  item = build_queue_item_hash(row)
  ahead = count_ahead(token)
  item[:ahead_count] = ahead
  wait_minutes = estimate_wait_minutes(ahead)
  item[:estimated_wait_minutes] = wait_minutes
  item[:estimated_wait_text] = format_wait_time(wait_minutes)

  json item
end

post '/api/call-next' do
  params = parse_request_body
  table_type = params['table_type'].to_s

  unless TABLE_TYPES.key?(table_type)
    status 400
    return json error: '无效的桌型，只能是 small 或 large'
  end

  customer = get_next_customer(table_type)

  unless customer
    status 404
    return json error: '当前没有等待的顾客'
  end

  token = customer[1]
  now = Time.now.iso8601

  get_db.execute(<<-SQL, QUEUE_STATUS[:called], now, token)
    UPDATE queue_items SET status = ?, called_at = ? WHERE token = ?
  SQL

  row = get_db.execute('SELECT * FROM queue_items WHERE token = ?', token).first
  json build_queue_item_hash(row)
end

post '/api/complete/:token' do
  token = params['token'].to_s.upcase

  row = get_db.execute('SELECT * FROM queue_items WHERE token = ?', token).first
  unless row
    status 404
    return json error: '取号凭证不存在'
  end

  now = Time.now.iso8601
  get_db.execute(<<-SQL, QUEUE_STATUS[:completed], now, token)
    UPDATE queue_items SET status = ?, completed_at = ? WHERE token = ?
  SQL

  row = get_db.execute('SELECT * FROM queue_items WHERE token = ?', token).first
  json build_queue_item_hash(row)
end

post '/api/cancel/:token' do
  token = params['token'].to_s.upcase

  row = get_db.execute('SELECT * FROM queue_items WHERE token = ?', token).first
  unless row
    status 404
    return json error: '取号凭证不存在'
  end

  current_status = row[5]
  if current_status != QUEUE_STATUS[:waiting]
    status 400
    status_text = case current_status
                  when QUEUE_STATUS[:called] then '已叫号'
                  when QUEUE_STATUS[:completed] then '已完成就餐'
                  when QUEUE_STATUS[:cancelled] then '已取消'
                  else current_status
                  end
    return json error: "当前状态为#{status_text}，无法取消"
  end

  now = Time.now.iso8601
  get_db.execute(<<-SQL, QUEUE_STATUS[:cancelled], now, token)
    UPDATE queue_items SET status = ?, completed_at = ? WHERE token = ?
  SQL

  row = get_db.execute('SELECT * FROM queue_items WHERE token = ?', token).first
  json build_queue_item_hash(row)
end

get '/api/queue/list/:table_type' do
  table_type = params['table_type'].to_s

  unless TABLE_TYPES.key?(table_type)
    status 400
    return json error: '无效的桌型，只能是 small 或 large'
  end

  rows = get_db.execute(<<-SQL, table_type, QUEUE_STATUS[:waiting])
    SELECT * FROM queue_items
    WHERE table_type = ? AND status = ?
    ORDER BY is_vip DESC, id ASC
  SQL

  json rows.map { |row| build_queue_item_hash(row) }
end

get '/api/statistics' do
  today = Date.today.iso8601
  date_start = "#{today} 00:00:00"
  date_end = "#{today} 23:59:59"

  total_today = get_db.execute(<<-SQL, date_start, date_end).flatten.first
    SELECT COUNT(*) FROM queue_items
    WHERE datetime(created_at, 'localtime') BETWEEN ? AND ?
  SQL

  total_vip = get_db.execute(<<-SQL, date_start, date_end).flatten.first
    SELECT COUNT(*) FROM queue_items WHERE is_vip = 1
      AND datetime(created_at, 'localtime') BETWEEN ? AND ?
  SQL

  waiting_count = get_db.execute(<<-SQL, QUEUE_STATUS[:waiting]).flatten.first
    SELECT COUNT(*) FROM queue_items WHERE status = ?
  SQL

  completed_count = get_db.execute(<<-SQL, QUEUE_STATUS[:completed], date_start, date_end).flatten.first
    SELECT COUNT(*) FROM queue_items WHERE status = ?
      AND datetime(created_at, 'localtime') BETWEEN ? AND ?
  SQL

  small_stats = get_db.execute(<<-SQL, 'small', date_start, date_end).first
    SELECT COALESCE(COUNT(*), 0),
           COALESCE(SUM(CASE WHEN status = 'waiting' THEN 1 ELSE 0 END), 0) as waiting,
           COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0) as completed
    FROM queue_items WHERE table_type = ?
      AND datetime(created_at, 'localtime') BETWEEN ? AND ?
  SQL

  large_stats = get_db.execute(<<-SQL, 'large', date_start, date_end).first
    SELECT COALESCE(COUNT(*), 0),
           COALESCE(SUM(CASE WHEN status = 'waiting' THEN 1 ELSE 0 END), 0) as waiting,
           COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0) as completed
    FROM queue_items WHERE table_type = ?
      AND datetime(created_at, 'localtime') BETWEEN ? AND ?
  SQL

  hourly_data = get_db.execute(<<-SQL, date_start, date_end)
    SELECT strftime('%H', datetime(created_at, 'localtime')) as hour,
           table_type,
           COUNT(*) as count
    FROM queue_items
    WHERE datetime(created_at, 'localtime') BETWEEN ? AND ?
    GROUP BY hour, table_type
    ORDER BY hour
  SQL

  hourly_stats = {}
  (9..21).each do |h|
    hour_key = h.to_s.rjust(2, '0')
    hourly_stats[hour_key] = { small: 0, large: 0, total: 0 }
  end

  hourly_data.each do |row|
    hour, ttype, count = row
    if hourly_stats.key?(hour)
      hourly_stats[hour][ttype.to_sym] = count
      hourly_stats[hour][:total] += count
    end
  end

  peak_hour = hourly_stats.max_by { |_h, data| data[:total] }
  peak_hour_data = if peak_hour
                     { hour: peak_hour[0], count: peak_hour[1][:total] }
                   else
                     { hour: nil, count: 0 }
                   end

  json(
    date: today,
    summary: {
      total_today: total_today,
      total_vip: total_vip,
      waiting_now: waiting_count,
      completed_today: completed_count,
      small_table: {
        total: small_stats[0],
        waiting: small_stats[1],
        completed: small_stats[2]
      },
      large_table: {
        total: large_stats[0],
        waiting: large_stats[1],
        completed: large_stats[2]
      }
    },
    hourly: hourly_stats,
    peak_hour: peak_hour_data
  )
end

get '/api/table-types' do
  json TABLE_TYPES
end
