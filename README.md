# Restaurant Queue API

餐厅排队叫号系统后端 API，基于 Ruby + Sinatra + SQLite，支持大小桌分流、VIP 插队、过号自动标记、重排、排队状态查询与当日统计。

## 目录结构

```
project6/
├── app.rb                  # 启动入口：中间件、DB 连接、加载各模块
├── config.ru               # Rack 部署配置
├── init_db.rb              # 数据库初始化脚本（重建表）
├── test_api.rb             # 集成测试脚本
├── helpers/
│   └── api_helper.rb       # JSON 解析、平均等待时间计算等通用方法
├── models/
│   ├── queue_item.rb       # QueueItem 模型（排队记录）
│   └── call_record.rb      # CallRecord 模型（叫号流水）
└── routes/
    ├── queue.rb            # 取号、查询状态、排队列表
    ├── call.rb             # 后厨叫号
    ├── management.rb       # 完成、取消、重排
    ├── stats.rb            # 当日统计
    ├── health.rb           # 健康检查
    └── test.rb             # 测试辅助接口
```

## 本地启动

环境要求：Ruby 2.7+（建议 3.0+）。

```bash
# 1. 安装依赖
bundle install

# 2. 初始化数据库（会创建 queue.db，首次运行或需要重置数据时执行）
ruby init_db.rb

# 3. 启动服务（默认端口 4567）
ruby app.rb -p 4567
# 或使用 rackup
rackup -p 4567

# 4. 验证服务
curl http://localhost:4567/health
# {"status":"ok","time":"..."}
```

运行完整集成测试（服务已启动的前提下）：

```bash
ruby test_api.rb
```

## 数据库表结构

数据库使用 SQLite，文件为 `queue.db`，共两张表。

### queue_items — 排队记录主表

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | INTEGER PRIMARY KEY | 主键 |
| `queue_number` | VARCHAR(10) | 排队号，例如 `A001`、`B002`、`V003` |
| `table_type` | VARCHAR(10) | 桌型：`large`（大桌，5人以上）/ `small`（小桌，2-4人） |
| `customer_token` | VARCHAR(64) | 取号凭证 UUID，顾客用它查询状态 |
| `vip` | BOOLEAN | 是否 VIP，默认 `false` |
| `status` | VARCHAR(20) | 状态：`waiting` / `called` / `completed` / `cancelled` / `expired` |
| `priority` | INTEGER | 优先级，用于同 VIP 等级内的排序 |
| `created_at` | TIMESTAMP | 取号时间 |
| `called_at` | TIMESTAMP | 叫号时间（被呼叫时写入） |
| `completed_at` | TIMESTAMP | 完成时间（入座后写入） |

**索引**：
- `customer_token` 唯一索引，确保每次取号凭证不重复
- `queue_number` 索引
- `table_type` + `status` + `created_at` 复合索引，加速叫号和查询排序

### call_records — 叫号流水表

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | INTEGER PRIMARY KEY | 主键 |
| `queue_item_id` | INTEGER | 关联 `queue_items.id` |
| `table_type` | VARCHAR(10) | 当时呼叫的桌型 |
| `called_at` | TIMESTAMP | 叫号时间 |

## VIP 插队与优先级逻辑

核心排序规则在 `QueueItem.next_waiting` 中，SQL 等价于：

```sql
ORDER BY vip DESC, priority DESC, created_at ASC
```

三层排序，依次解释：

1. **VIP 优先**（`vip DESC`）：VIP 顾客始终排在普通顾客前面，无论什么时候取号。
2. **同等级优先级**（`priority DESC`）：同是 VIP 时，取号越晚 `priority` 越大，反而越靠前——因为新的 VIP 应该比更早的 VIP 更优先（模拟现场会员插队的"后来反而先被服务"的体验）。普通顾客 `priority` 恒为 `0`。
3. **取号时间兜底**（`created_at ASC`）：VIP 等级和优先级都相同时，按取号时间先到先得。

举例：

| 顺序 | 顾客 | VIP | priority | created_at |
|------|------|-----|----------|------------|
| 1 号被叫 | 顾客 C | ✅ | 3 | 12:03 |
| 2 号被叫 | 顾客 B | ✅ | 2 | 12:02 |
| 3 号被叫 | 顾客 A | ✅ | 1 | 12:01 |
| 4 号被叫 | 顾客 D | ❌ | 0 | 11:55 |
| 5 号被叫 | 顾客 E | ❌ | 0 | 11:58 |

过号重排后 VIP 身份和优先级都会被**清零**（见 `PUT /api/queue/:token/requeue`），避免过号的 VIP 仍插队。

## 状态流转

```
           ┌─────────────── 叫号 ───────────────┐
           ▼                                    │
   ┌─────────────┐   叫号   ┌─────────────┐      │
   │   waiting   │ ──────▶ │   called    │──┐   │
   └─────────────┘         └─────────────┘  │   │
          │                      │           │   │
          │ 取消                 │ 超时3分钟  │   │
          ▼                      ▼           │   │
   ┌─────────────┐         ┌─────────────┐   │   │
   │  cancelled  │         │   expired   │   │   │
   └─────────────┘         └─────────────┘   │   │
                                   │          │   │
                                   │ 重排     │ 完成
                                   ▼          │   │
                            回 waiting ◀──────┘   │
                                                  │
   ┌─────────────┐                                │
   │  completed  │ ◀─────────────────────────────┘
   └─────────────┘
```

合法流转：
- `waiting` → `called`（叫号）
- `called` → `completed`（到店入座）
- `called` → `expired`（超时 3 分钟未到，自动检测）
- `expired` → `waiting`（顾客申请重排，排队尾、VIP 清零）
- `waiting` → `cancelled`（顾客取消）
- `called` → `cancelled`（被叫号后顾客自行取消）

`complete` 接口只接受从 `called` 流转，其余状态一律返回 `400 Bad Request`。

## 预估等待时长

取号和查询状态时返回 `estimated_wait_minutes`，粗略计算：

```
estimated_wait_minutes = (ahead_count + 1) * 15
```

- `ahead_count`：前面还有几桌
- 固定每桌 15 分钟
- 非 `waiting` 状态下返回 `null`（已叫号/已完成/已过号不再预估）

## API 接口说明

所有接口默认返回 JSON，响应头 `Content-Type: application/json`。全局支持 CORS。

---

### 1. 顾客扫码取号

**`POST /api/take_number`**

请求体：

```json
{
  "table_type": "small",
  "vip": false
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `table_type` | ✅ | `"large"` 或 `"small"` |
| `vip` | ❌ | 布尔，默认 `false` |

响应示例（`200 OK`）：

```json
{
  "queue_number": "B002",
  "customer_token": "f87c3d0e-5a4b-4c3d-9e8f-2d1e3a4b5c6d",
  "table_type": "small",
  "vip": false,
  "status": "waiting",
  "ahead_count": 1,
  "estimated_wait_minutes": 30,
  "created_at": "2026-06-23T12:30:00+08:00"
}
```

失败（桌型无效）：

```json
{
  "error": "Invalid table_type, must be \"large\" or \"small\""
}
```

---

### 2. 查询排队状态

**`GET /api/queue_status/:customer_token`**

路径参数：
- `customer_token`：取号时返回的凭证 UUID

响应示例（`200 OK`，waiting 状态）：

```json
{
  "queue_number": "B002",
  "table_type": "small",
  "vip": false,
  "status": "waiting",
  "ahead_count": 1,
  "estimated_wait_minutes": 30,
  "created_at": "2026-06-23T12:30:00+08:00",
  "called_at": null,
  "message": "You are 2 in the queue"
}
```

响应示例（已叫号）：

```json
{
  "queue_number": "B002",
  "table_type": "small",
  "vip": false,
  "status": "called",
  "ahead_count": null,
  "estimated_wait_minutes": null,
  "created_at": "2026-06-23T12:30:00+08:00",
  "called_at": "2026-06-23T12:45:00+08:00",
  "message": "Your turn! Please proceed to your table"
}
```

响应示例（过号）：

```json
{
  "queue_number": "B002",
  "table_type": "small",
  "vip": false,
  "status": "expired",
  "ahead_count": null,
  "estimated_wait_minutes": null,
  "created_at": "2026-06-23T12:30:00+08:00",
  "called_at": "2026-06-23T12:45:00+08:00",
  "message": "Your queue has expired (no-show). You can requeue at the end of the line."
}
```

失败（凭证无效，`404`）：

```json
{
  "error": "Invalid customer token"
}
```

---

### 3. 后厨叫号

**`POST /api/call_next`**

请求体：

```json
{
  "table_type": "small"
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `table_type` | ✅ | `"large"` 或 `"small"`，叫哪个桌型的下一位 |

响应示例（`200 OK`，成功叫到 VIP）：

```json
{
  "queue_number": "V001",
  "table_type": "small",
  "vip": true,
  "called_at": "2026-06-23T12:45:00+08:00",
  "message": "Calling V001 to small table"
}
```

失败（没人排队，`404`）：

```json
{
  "message": "No customers waiting in queue"
}
```

> 叫号后系统会在**每次请求的 before 钩子**里自动扫描所有 `called` 状态记录，超过 3 分钟未完成（`completed_at` 为空且 `called_at` 距今 > 180s）的会被标记为 `expired`。

---

### 4. 完成叫号（到店入座）

**`PUT /api/queue/:customer_token/complete`**

路径参数：
- `customer_token`：取号凭证

响应示例（`200 OK`）：

```json
{
  "message": "Queue completed successfully",
  "status": "completed"
}
```

失败（状态不是 `called`，`400`）：

```json
{
  "error": "Cannot complete a customer in 'waiting' status. Only 'called' status can be completed."
}
```

---

### 5. 取消排队

**`PUT /api/queue/:customer_token/cancel`**

路径参数：
- `customer_token`：取号凭证

响应示例（`200 OK`）：

```json
{
  "message": "Queue cancelled successfully",
  "status": "cancelled"
}
```

---

### 6. 过号重排

**`PUT /api/queue/:customer_token/requeue`**

仅 `expired` 状态的顾客可以调用。重排规则：
- VIP 身份**取消**（`vip: false`）
- 优先级**归零**（`priority: 0`）
- `created_at` 更新为当前时间，自然排到队尾

响应示例（`200 OK`）：

```json
{
  "message": "Requeued successfully at the end of the line",
  "queue_number": "B002",
  "status": "waiting",
  "ahead_count": 3,
  "estimated_wait_minutes": 60
}
```

失败（非过号状态，`400`）：

```json
{
  "error": "Only expired (no-show) customers can requeue"
}
```

---

### 7. 排队列表

**`GET /api/queue/list`**

查询参数：
- `table_type`（可选）：`large` / `small`，按桌型筛选
- `status`（可选）：`waiting`（默认）/ `called` / `completed` / `cancelled` / `expired`

响应示例：

```json
{
  "queue": [
    {
      "queue_number": "V001",
      "table_type": "small",
      "vip": true,
      "status": "waiting",
      "ahead_count": 0,
      "created_at": "2026-06-23T12:32:00+08:00",
      "called_at": null
    },
    {
      "queue_number": "B001",
      "table_type": "small",
      "vip": false,
      "status": "waiting",
      "ahead_count": 1,
      "created_at": "2026-06-23T12:30:00+08:00",
      "called_at": null
    }
  ],
  "count": 2
}
```

---

### 8. 当日排队统计

**`GET /api/stats/today`**

响应示例：

```json
{
  "date": "2026-06-23",
  "summary": {
    "total_customers_today": 15,
    "large_table_count": 5,
    "small_table_count": 10,
    "vip_count": 3,
    "currently_waiting": 4,
    "currently_called": 1,
    "expired_count": 1,
    "completed_count": 9,
    "peak_hour": "12:00-13:00",
    "peak_customers": 7
  },
  "hourly_stats": [
    {
      "hour": 11,
      "time_range": "11:00-12:00",
      "total_customers": 3,
      "large_table": 1,
      "small_table": 2,
      "vip_customers": 1,
      "avg_wait_time": 15
    },
    {
      "hour": 12,
      "time_range": "12:00-13:00",
      "total_customers": 7,
      "large_table": 2,
      "small_table": 5,
      "vip_customers": 2,
      "avg_wait_time": 30
    }
  ]
}
```

`hourly_stats` 过滤掉了没有顾客的时段。`avg_wait_time` 单位为分钟，基于当日实际完成顾客的 `created_at → completed_at` 差值计算，无数据时为 `0`。

---

### 9. 健康检查

**`GET /health`**

```json
{
  "status": "ok",
  "time": "2026-06-23T12:30:00+08:00"
}
```

---

### 10. 测试辅助接口（仅开发环境）

**`POST /api/test/simulate_timeout`**

把指定顾客的 `called_at` 回拨到 4 分钟前并触发一次超时检测，用于测试过号逻辑而无需真等 3 分钟。

请求体：

```json
{
  "customer_token": "f87c3d0e-..."
}
```

## 常见问题

**Q: 每日排队号会自动重置吗？**
会。`QueueItem.generate_queue_number` 只取当日（`created_at >= Date.today`）的最大序号 + 1，每天从 001 重新开始。

**Q: 大桌和小桌是分开排队的吗？**
是。`table_type` 是叫号查询和排序的第一过滤条件，大桌小桌互不干扰。

**Q: 过号重排后还是 VIP 吗？**
不是。过号意味着顾客错过了叫号机会，重排后 VIP 身份和优先级都会清零，公平排队。

**Q: 为什么不用真的后台任务做超时检测？**
当前规模不大，用 `before` 钩子在每次请求到来时扫一次叫号超过 3 分钟的记录，足够简单可靠，也避免引入 Sidekiq 等额外依赖。后续高并发可替换为定时任务。
