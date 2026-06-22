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

def extract(res, key)
  JSON.parse(res.body)[key]
end

puts "=========================================="
puts "餐厅排队叫号 API 测试"
puts "=========================================="
puts

puts "1. 健康检查"
request(:get, '/health')
sleep 0.3

puts "2. 顾客1 - 取小桌号 (普通)"
res1 = request(:post, '/api/take_number', { table_type: 'small' })
token1 = extract(res1, 'customer_token')
sleep 0.3

puts "3. 顾客2 - 取小桌号 (普通)"
res2 = request(:post, '/api/take_number', { table_type: 'small' })
token2 = extract(res2, 'customer_token')
sleep 0.3

puts "4. 顾客3 - 取小桌号 (VIP)"
res3 = request(:post, '/api/take_number', { table_type: 'small', vip: true })
token3 = extract(res3, 'customer_token')
sleep 0.3

puts "5. 顾客4 - 取大桌号 (普通)"
res4 = request(:post, '/api/take_number', { table_type: 'large' })
token4 = extract(res4, 'customer_token')
sleep 0.3

puts "6. 查询顾客1排队状态 - ahead_count应为1，estimated_wait_minutes应为30"
request(:get, "/api/queue_status/#{token1}")
sleep 0.3

puts "7. 后厨叫号 - 小桌 (应先叫VIP顾客3)"
request(:post, '/api/call_next', { table_type: 'small' })
sleep 0.3

puts "8. 后厨叫号 - 小桌 (应叫顾客1)"
request(:post, '/api/call_next', { table_type: 'small' })
sleep 0.3

puts "9. 查询顾客1状态 - 应为 called，ahead_count应为null，estimated_wait_minutes应为null"
request(:get, "/api/queue_status/#{token1}")
sleep 0.3

puts "10. [BUG FIX] waiting状态的顾客2尝试complete - 应该被拒绝(400)"
request(:put, "/api/queue/#{token2}/complete")
sleep 0.3

puts "11. called状态的顾客1完成 - 应该成功"
request(:put, "/api/queue/#{token1}/complete")
sleep 0.3

puts "12. 查询已完成的顾客1状态 - ahead_count应为null"
request(:get, "/api/queue_status/#{token1}")
sleep 0.3

puts "13. 后厨叫号 - 小桌 (应叫顾客2)"
request(:post, '/api/call_next', { table_type: 'small' })
sleep 0.3

puts "14. 模拟顾客2过号"
request(:post, '/api/test/simulate_timeout', { customer_token: token2 })
sleep 0.3

puts "15. 查询过号顾客2状态 - ahead_count应为null"
request(:get, "/api/queue_status/#{token2}")
sleep 0.3

puts "16. 过号顾客重排"
request(:put, "/api/queue/#{token2}/requeue")
sleep 0.3

puts "17. 顾客5 - 取大桌号 (VIP)"
res5 = request(:post, '/api/take_number', { table_type: 'large', vip: true })
token5 = extract(res5, 'customer_token')
sleep 0.3

puts "18. 后厨叫号 - 大桌 (应先叫VIP顾客5)"
request(:post, '/api/call_next', { table_type: 'large' })
sleep 0.3

puts "19. 模拟顾客5过号后重排 - VIP应被取消"
request(:post, '/api/test/simulate_timeout', { customer_token: token5 })
sleep 0.3
request(:put, "/api/queue/#{token5}/requeue")
sleep 0.3

puts "20. 后厨叫号 - 大桌 (应叫普通顾客4)"
request(:post, '/api/call_next', { table_type: 'large' })
sleep 0.3

puts "21. 完成顾客4"
request(:put, "/api/queue/#{token4}/complete")
sleep 0.3

puts "22. [BUG FIX] 再次complete已完成的顾客4 - 应该被拒绝(400)"
request(:put, "/api/queue/#{token4}/complete")
sleep 0.3

puts "23. 当日排队统计"
request(:get, '/api/stats/today')
sleep 0.3

puts "=========================================="
puts "测试完成！"
puts "=========================================="
