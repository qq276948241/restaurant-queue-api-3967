require 'json'
require 'net/http'
require 'uri'

BASE_URL = 'http://localhost:4567'

def request(method, path, body = nil)
  uri = URI("#{BASE_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  
  case method
  when :get
    req = Net::HTTP::Get.new(uri)
  when :post
    req = Net::HTTP::Post.new(uri)
  when :put
    req = Net::HTTP::Put.new(uri)
  end
  
  req['Content-Type'] = 'application/json'
  req.body = body.to_json if body
  
  res = http.request(req)
  puts "=== #{method.upcase} #{path} ==="
  puts "Status: #{res.code}"
  if res.body && !res.body.empty?
    json = JSON.parse(res.body) rescue res.body
    puts JSON.pretty_generate(json)
  end
  puts
  res
end

puts "=========================================="
puts "餐厅排队叫号 API 测试"
puts "=========================================="
puts

puts "1. 健康检查"
request(:get, '/health')
sleep 0.5

puts "2. 顾客1 - 取小桌号 (普通)"
res1 = request(:post, '/api/take_number', { table_type: 'small' })
token1 = JSON.parse(res1.body)['customer_token']
sleep 0.5

puts "3. 顾客2 - 取小桌号 (普通)"
res2 = request(:post, '/api/take_number', { table_type: 'small' })
token2 = JSON.parse(res2.body)['customer_token']
sleep 0.5

puts "4. 顾客3 - 取大桌号 (VIP)"
res3 = request(:post, '/api/take_number', { table_type: 'large', vip: true })
token3 = JSON.parse(res3.body)['customer_token']
sleep 0.5

puts "5. 顾客4 - 取大桌号 (普通)"
res4 = request(:post, '/api/take_number', { table_type: 'large' })
token4 = JSON.parse(res4.body)['customer_token']
sleep 0.5

puts "6. 顾客5 - 取小桌号 (VIP) - 测试插队"
res5 = request(:post, '/api/take_number', { table_type: 'small', vip: true })
token5 = JSON.parse(res5.body)['customer_token']
sleep 0.5

puts "7. 查询顾客1的排队状态"
request(:get, "/api/queue_status/#{token1}")
sleep 0.5

puts "8. 查询顾客5(VIP)的排队状态 - 应该排在最前面"
request(:get, "/api/queue_status/#{token5}")
sleep 0.5

puts "9. 查看当前排队列表 (小桌)"
request(:get, '/api/queue/list?table_type=small')
sleep 0.5

puts "10. 后厨叫号 - 小桌"
request(:post, '/api/call_next', { table_type: 'small' })
sleep 0.5

puts "11. 后厨叫号 - 小桌 (应该叫下一位VIP)"
request(:post, '/api/call_next', { table_type: 'small' })
sleep 0.5

puts "12. 后厨叫号 - 大桌 (应该先叫VIP)"
request(:post, '/api/call_next', { table_type: 'large' })
sleep 0.5

puts "13. 查询顾客1的排队状态 (应该已叫号)"
request(:get, "/api/queue_status/#{token1}")
sleep 0.5

puts "14. 完成顾客1的叫号"
request(:put, "/api/queue/#{token1}/complete")
sleep 0.5

puts "15. 查看当前排队列表"
request(:get, '/api/queue/list')
sleep 0.5

puts "16. 当日排队统计"
request(:get, '/api/stats/today')
sleep 0.5

puts "=========================================="
puts "测试完成！"
puts "=========================================="
