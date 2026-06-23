require 'net/http'
require 'json'
require 'uri'

uri = URI('http://localhost:4568/api/tickets')
http = Net::HTTP.new(uri.host, uri.port)

puts "=== 1. 测试取号接口（小桌）==="
request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
request.body = { table_type: 'small', vip: false }.to_json
response = http.request(request)
puts "状态码: #{response.code}"
ticket_small = JSON.parse(response.body)
puts JSON.pretty_generate(ticket_small)
puts

puts "=== 2. 测试取号接口（大桌）==="
request2 = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
request2.body = { table_type: 'large', vip: false }.to_json
response2 = http.request(request2)
puts "状态码: #{response2.code}"
ticket_large = JSON.parse(response2.body)
puts JSON.pretty_generate(ticket_large)
puts

puts "=== 3. 测试取号接口（VIP小桌）==="
request3 = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
request3.body = { table_type: 'small', vip: true }.to_json
response3 = http.request(request3)
puts "状态码: #{response3.code}"
ticket_vip = JSON.parse(response3.body)
puts JSON.pretty_generate(ticket_vip)
puts

puts "=== 4. 测试查询排队状态 ==="
token = ticket_small['ticket_token']
uri4 = URI("http://localhost:4568/api/tickets/#{token}")
response4 = http.get(uri4.path)
puts "状态码: #{response4.code}"
status = JSON.parse(response4.body)
puts JSON.pretty_generate(status)
puts "前面还有 #{status['waiting_ahead']} 桌"
puts

puts "=== 5. 测试叫号接口（小桌）==="
uri5 = URI('http://localhost:4568/api/call-next')
request5 = Net::HTTP::Post.new(uri5.path, 'Content-Type' => 'application/json')
request5.body = { table_type: 'small' }.to_json
response5 = http.request(request5)
puts "状态码: #{response5.code}"
called = JSON.parse(response5.body)
puts "被叫到的号: #{called['ticket_number']}, VIP: #{called['vip']}"
puts "注意: VIP优先，应该先叫到VIP顾客"
puts

puts "=== 6. 测试当日统计 ==="
uri6 = URI('http://localhost:4568/api/stats/daily')
response6 = http.get(uri6.path)
puts "状态码: #{response6.code}"
stats = JSON.parse(response6.body)
puts "今日总取号数: #{stats['total_tickets']}"
puts "小桌统计: #{stats['table_type_stats']['small']}"
puts "大桌统计: #{stats['table_type_stats']['large']}"
puts "VIP统计: #{stats['vip_stats']}"
puts "高峰时段: #{stats['peak_hour']}"
puts

puts "=== 7. 测试队列详情 ==="
uri7 = URI('http://localhost:4568/api/stats/queue/small')
response7 = http.get(uri7.path)
puts "状态码: #{response7.code}"
queue = JSON.parse(response7.body)
puts "等待人数: #{queue['waiting_count']}"
queue['queue'].each do |item|
  puts "  位置#{item['position']}: 号#{item['ticket_number']} VIP=#{item['vip']} 等待#{item['wait_time']}分钟"
end
puts

puts "=== 测试完成 ==="
