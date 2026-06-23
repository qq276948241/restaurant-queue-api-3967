# 排队叫号系统架构文档

## 项目结构

```
project6/
├── app.rb              # 路由层：Sinatra 应用，参数校验 + HTTP 响应
├── queue_service.rb    # 业务逻辑层：QueueService 模块，所有核心逻辑
├── config.ru           # Rack 启动入口
├── Gemfile             # 依赖声明
└── queue.db            # SQLite 数据库（运行时自动创建）
```

## 分层职责

### 路由层 — [app.rb](file:///D:/code/ai-prompt/solo-chrome-dev-F12/repos/repo6/project6/app.rb)

`QueueApp < Sinatra::Base`，只做三件事：

1. **参数解析**：`parse_body` 从 request body 提取 JSON
2. **参数校验**：`validate_table_type` 校验桌型合法性
3. **调用 Service + 返回 HTTP**：每个路由方法体不超过 10 行

路由层**不做**任何业务判断，不直接操作数据库，不计算 position 或 ahead_count。

```ruby
# 典型路由方法——参数校验 → 调用 Service → 返回 JSON
post '/api/queue/call_next' do
  params = parse_body
  table_type = params['table_type']

  err = validate_table_type(table_type)
  return err if err

  ticket = QueueService.call_next(table_type)
  return error_json('no one waiting in queue', 404) unless ticket

  json ticket
end
```

### 业务逻辑层 — [queue_service.rb](file:///D:/code/ai-prompt/solo-chrome-dev-F12/repos/repo6/project6/queue_service.rb)

`QueueService` 模块（纯类方法，无实例状态），封装所有核心逻辑：

| 公共方法 | 对应接口 | 作用 |
|---|---|---|
| `take_number` | POST /api/queue/take | 取号 |
| `vip_insert` | POST /api/queue/vip_insert | VIP 插队 |
| `call_next` | POST /api/queue/call_next | 叫下一位 |
| `confirm_served` | POST /api/queue/confirm_served | 确认入座 |
| `handle_miss` | POST /api/queue/miss | 手动过号 |
| `cancel` | POST /api/queue/cancel | 取消排队 |
| `status` | GET /api/queue/status/:token | 查询状态 |
| `current_queue` | GET /api/queue/current | 当前队列 |
| `summary` | GET /api/queue/summary | 概览 |
| `stats` | GET /api/queue/stats | 当日统计 |

内部私有方法：

| 方法 | 作用 |
|---|---|
| `normalize_positions` | 队列变动后重排紧凑位次（核心） |
| `process_expired_calls` | 扫描超时未确认的号，触发过号 |
| `process_miss` | 执行过号逻辑：miss_count 判断、重排或作废 |
| `next_number` | 每日分桌型自增编号 |
| `enrich_ticket` | 统一装配返回字段（ahead_count、预估时间等） |
| `waiting_ahead` | 计算前面还有几桌 |
| `estimate_wait_minutes` | 预估等待时间 |

---

## 数据模型

### queue_tickets 表

| 字段 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PK | 自增主键 |
| ticket_token | STRING UNIQUE | 16 位十六进制凭证，顾客扫码查状态用 |
| ticket_number | INTEGER | 当日分桌型自增编号（如小桌1号、大桌1号） |
| table_type | STRING | `small` 或 `large`，两队列完全独立 |
| vip | BOOLEAN | 是否 VIP |
| status | STRING | 状态机（见下方） |
| position | INTEGER | 队内位次，由 `normalize_positions` 统一分配 |
| miss_count | INTEGER | 过号次数，达到 2 次自动作废 |
| created_at | DATETIME | 取号时间 |
| called_at | DATETIME | 最近一次叫号时间 |
| served_at | DATETIME | 确认入座时间 |

### daily_counters 表

| 字段 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PK | 自增主键 |
| table_type | STRING | 桌型 |
| counter | INTEGER | 当日已发出的最大编号 |
| date | DATE | 日期 |

联合唯一约束 `(table_type, date)` 保证每日每桌型自增编号独立。

### 状态机

```
                     ┌──────────────────────┐
                     │                      │
                     ▼                      │
  waiting ──→ called ──→ served             │
     │           │                          │
     │           ├── miss (miss_count < 2) ──┘
     │           │
     │           └── miss (miss_count = 2) ──→ missed
     │
     └── cancel ──→ cancelled
```

- `waiting` → `called`：后厨叫号
- `called` → `served`：客人确认到店入座
- `called` → `waiting`：过号（第 1 次），重排到队尾
- `called` → `missed`：过号（第 2 次），直接作废
- `waiting`/`called` → `cancelled`：客人主动取消

---

## 完整请求流转

### 主流程：顾客扫码取号 → 叫号 → 入座

```
顾客扫码                    后厨                       系统
   │                        │                          │
   │  POST /api/queue/take  │                          │
   │  {table_type, vip}     │                          │
   │───────────────────────►│──────────────────────────►│
   │                        │                          │  1. next_number 分配编号
   │                        │                          │  2. 创建 QueueTicket (position=0)
   │                        │                          │  3. normalize_positions 重排
   │                        │                          │  4. enrich_ticket 装配响应
   │  {token, number,       │                          │
   │   position, ahead_count,                          │
   │   estimated_wait_minutes}                         │
   │◄───────────────────────│◄─────────────────────────│
   │                        │                          │
   │                        │  POST /api/queue/call_next│
   │                        │  {table_type}            │
   │                        │─────────────────────────►│
   │                        │                          │  1. process_expired_calls
   │                        │                          │  2. 取 position 最小的 waiting 票
   │                        │                          │  3. status → called
   │                        │                          │  4. normalize_positions 重排
   │                        │  {ticket, called_at}     │
   │                        │◄─────────────────────────│
   │                        │                          │
   │  顾客到店，确认入座     │                          │
   │  POST /confirm_served  │                          │
   │  {ticket_token}        │                          │
   │───────────────────────►│──────────────────────────►│
   │                        │                          │  status → served
   │  {status: served}      │                          │
   │◄───────────────────────│◄─────────────────────────│
```

### 顾客查进度

```
顾客                        系统
  │                          │
  │  GET /api/queue/status/:token
  │─────────────────────────►│
  │                          │  1. 查 ticket 记录
  │                          │  2. waiting_ahead 算前面几桌
  │                          │  3. estimate_wait_minutes 估算时间
  │  {status, ahead_count,   │
  │   estimated_wait_minutes}│
  │◄─────────────────────────│
```

---

## 过号机制详解

### 触发方式

1. **自动过号**：`call_next` 时先调用 `process_expired_calls`，扫描所有 `called` 状态且 `called_at` 距今超过 180 秒的票
2. **手动过号**：后厨调用 `POST /api/queue/miss`，立即对当前被叫到的票执行过号

### 过号执行流程（[process_miss](file:///D:/code/ai-prompt/solo-chrome-dev-F12/repos/repo6/project6/queue_service.rb#L237-L247))

```
process_miss(ticket)
    │
    ▼
miss_count += 1
    │
    ├─ miss_count < 2 ?
    │     YES → status = waiting
    │           called_at = nil
    │           （等 normalize_positions 把它排到队尾）
    │
    └─ miss_count >= 2 ?
          YES → status = missed
                （作废，从队列消失）
```

### 关键：normalize_positions 保证位次正确

过号后不再手动赋 position，而是由 [normalize_positions](file:///D:/code/ai-prompt/solo-chrome-dev-F12/repos/repo6/project6/queue_service.rb#L197-L206) 统一重排。排序规则：

```
ORDER BY miss_count ASC, vip DESC, created_at ASC
```

三层排序含义：

| 优先级 | 排序键 | 含义 |
|---|---|---|
| 1 | miss_count ASC | 未过号的人优先叫号，过号的人排到当前层末尾 |
| 2 | vip DESC | 同层内 VIP 优先 |
| 3 | created_at ASC | 同层同 VIP 按取号时间先来先叫 |

### 过号场景示例

```
初始队列:  #2(pos=1) #3(pos=2) #1(pos=3, miss=1) #4-VIP(pos=4, miss=1)

叫号 → #2 被叫走 → 重排:
  #3(pos=1) #4-VIP(pos=2) #1(pos=3)

叫号 → #3 被叫走 → 重排:
  #4-VIP(pos=1) #1(pos=2)

叫号 → #4-VIP 被叫走 → 重排:
  #1(pos=1)

叫号 → #1 被叫走 → 队列空
```

注意：#1 和 #4-VIP 都 miss=1，在同一层内 VIP#4 仍然优先于 #1 被叫到。

---

## VIP 插队详解

### 两种入口

1. **取号时标记 VIP**：`POST /api/queue/take` 传 `vip: true`
2. **VIP 专用插队接口**：`POST /api/queue/vip_insert`

两种方式效果相同——创建 ticket 后调用 `normalize_positions`，VIP 的 `vip=true` 在排序时获得优先。

### VIP 排序规则

VIP 不做"插到第几个"的手动计算，而是通过 `normalize_positions` 的排序规则自然体现：

- **miss_count=0 层**：所有未过号的票，VIP 排在非 VIP 前面
- **miss_count=1 层**：所有过号 1 次的票，VIP 仍排在非 VIP 前面，但整个 miss=1 层排在 miss=0 层后面

所以 VIP 过号后不会一直霸占队首，而是排到**所有未过号的人**后面，但在**同层过号的人**中仍优先。

### VIP + 过号交互场景

```
1. 取号: #1(普通) #2(普通) #3(普通)
   队列: #1(pos=1) #2(pos=2) #3(pos=3)

2. VIP插队: #4-VIP
   队列: #4-VIP(pos=1) #1(pos=2) #2(pos=3) #3(pos=4)

3. 叫号 → #4-VIP, 过号(miss=1)
   队列: #1(pos=1) #2(pos=2) #3(pos=3) #4-VIP(pos=4)
   ↑ #4-VIP 排到 miss=1 层（只有它），在所有 miss=0 的人后面

4. 叫号 → #1, 过号(miss=1)
   队列: #2(pos=1) #3(pos=2) #4-VIP(pos=3) #1(pos=4)
   ↑ 同层(miss=1) 内 VIP 优先，#4-VIP(pos=3) 排在 #1(pos=4) 前面

5. 叫号 → #2, 入座 → 叫号 → #3, 入座

6. 叫号 → #4-VIP（同层VIP优先）
   叫号 → #1
```

---

## normalize_positions 触发时机

这是系统正确性的关键方法，在以下 5 个操作后都会调用：

| 操作 | 为什么需要重排 |
|---|---|
| `take_number` | 新票加入队列 |
| `vip_insert` | 新 VIP 加入队列 |
| `call_next` | 被叫的人离开 waiting 队列 |
| `handle_miss` | 过号的人重新回到 waiting 队列 |
| `cancel` | 取消的人离开 waiting 队列 |

`confirm_served` 不需要重排——served 状态的票已经不在 waiting 队列里，不影响 position。

---

## 配置常量

定义在 [queue_service.rb](file:///D:/code/ai-prompt/solo-chrome-dev-F12/repos/repo6/project6/queue_service.rb#L7-L11)：

| 常量 | 值 | 说明 |
|---|---|---|
| `MAX_MISS` | 2 | 最大过号次数，达到后作废 |
| `CALL_TIMEOUT_SECONDS` | 180 | 叫号后多久未确认自动过号 |
| `AVG_MEAL_MINUTES` | small: 30, large: 45 | 平均用餐时长，用于预估等待时间 |

修改这些值即可调整系统行为，无需改动业务逻辑。

---

## API 速查

| 方法 | 路径 | 请求体 | 成功状态码 |
|---|---|---|---|
| POST | /api/queue/take | `{table_type, vip}` | 201 |
| POST | /api/queue/vip_insert | `{table_type}` | 201 |
| POST | /api/queue/call_next | `{table_type}` | 200 |
| POST | /api/queue/confirm_served | `{ticket_token}` | 200 |
| POST | /api/queue/miss | `{ticket_token}` | 200 |
| POST | /api/queue/cancel | `{ticket_token}` | 200 |
| GET | /api/queue/status/:ticket_token | — | 200 |
| GET | /api/queue/current | ?table_type=small | 200 |
| GET | /api/queue/summary | — | 200 |
| GET | /api/queue/stats | ?date=2026-06-23 | 200 |
