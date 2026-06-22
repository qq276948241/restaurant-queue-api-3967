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
puts "餐厅排队叫号 API 测试 (含过号/重排/预估)"
puts "=========================================="
puts

puts "1. 健康检查"
request(:get, '/health')
sleep 0.3

puts "2. 顾客1 - 取小桌号 (普通) - 应返回 estimated_wait_minutes: 15"
res1 = request(:post, '/api/take_number', { table_type: 'small' })
token1 = extract(res1, 'customer_token')
sleep 0.3

puts "3. 顾客2 - 取小桌号 (普通) - 应返回 estimated_wait_minutes: 30"
res2 = request(:post, '/api/take_number', { table_type: 'small' })
token2 = extract(res2, 'customer_token')
sleep 0.3

puts "4. 顾客3 - 取小桌号 (VIP) - 测试插队，estimated_wait_minutes: 15"
res3 = request(:post, '/api/take_number', { table_type: 'small', vip: true })
token3 = extract(res3, 'customer_token')
sleep 0.3

puts "5. 顾客4 - 取大桌号 (普通) - estimated_wait_minutes: 15"
res4 = request(:post, '/api/take_number', { table_type: 'large' })
token4 = extract(res4, 'customer_token')
sleep 0.3

puts "6. 查询顾客1排队状态 - 应显示 ahead_count 和 estimated_wait_minutes"
request(:get, "/api/queue_status/#{token1}")
sleep 0.3

puts "7. 后厨叫号 - 小桌 (应先叫VIP顾客3)"
request(:post, '/api/call_next', { table_type: 'small' })
sleep 0.3

puts "8. 后厨叫号 - 小桌 (应叫顾客1)"
request(:post, '/api/call_next', { table_type: 'small' })
sleep 0.3

puts "9. 查询顾客1状态 - 应为 called"
request(:get, "/api/queue_status/#{token1}")
sleep 0.3

puts "10. 模拟过号：手动将顾客1的 called_at 设为4分钟前"
request(:post, '/api/test/simulate_timeout', { customer_token: token1 })
sleep 0.3

puts "11. 查询顾客1状态 - 应为 expired (过号)"
request(:get, "/api/queue_status/#{token1}")
sleep 0.3

puts "12. 查看过号列表"
request(:get, '/api/queue/list?status=expired')
sleep 0.3

puts "13. 非过号顾客尝试重排 - 应该失败"
request(:put, "/api/queue/#{token2}/requeue")
sleep 0.3

puts "14. 过号顾客重排 - 应成功并排到队尾"
request(:put, "/api/queue/#{token1}/requeue")
sleep 0.3

puts "15. 查询重排后顾客1状态 - 应为 waiting，排在队尾"
request(:get, "/api/queue_status/#{token1}")
sleep 0.3

puts "16. 查看当前小桌排队列表 - 顾客1应在队尾"
request(:get, '/api/queue/list?table_type=small')
sleep 0.3

puts "17. 顾客5 - 取大桌号 (VIP)"
res5 = request(:post, '/api/take_number', { table_type: 'large', vip: true })
token5 = extract(res5, 'customer_token')
sleep 0.3

puts "18. 后厨叫号 - 大桌 (应先叫VIP顾客5)"
request(:post, '/api/call_next', { table_type: 'large' })
sleep 0.3

puts "19. 模拟顾客5过号"
request(:post, '/api/test/simulate_timeout', { customer_token: token5 })
sleep 0.3

puts "20. VIP过号后重排 - VIP身份应被取消，排到队尾"
request(:put, "/api/queue/#{token5}/requeue")
sleep 0.3

puts "21. 查询重排后顾客5状态 - vip应为false，排在队尾"
request(:get, "/api/queue_status/#{token5}")
sleep 0.3

puts "22. 后厨叫号 - 大桌 (应叫普通顾客4)"
request(:post, '/api/call_next', { table_type: 'large' })
sleep 0.3

puts "23. 完成顾客4"
request(:put, "/api/queue/#{token4}/complete")
sleep 0.3

puts "24. 当日排队统计 - 应含 expired_count"
request(:get, '/api/stats/today')
sleep 0.3

puts "=========================================="
puts "测试完成！"
puts "=========================================="
