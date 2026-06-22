# Restaurant Queue API

基于 Ruby + Sinatra 的餐厅排队叫号系统 API。

## 功能特性

- 顾客扫码取号（区分大桌/小桌）
- 后厨叫号（叫下一位）
- 顾客查询排队位置（前面还有几桌）
- VIP 优先插队逻辑
- 当日排队统计（各时段高峰情况）

## 快速开始

```bash
bundle install
rackup -p 4567
```

## API 接口

### 1. 取号 `POST /tickets`

顾客扫码取号。

**请求体:**

```json
{
  "table_type": "small",
  "people_count": 2,
  "vip": false
}
```

| 参数 | 类型 | 说明 |
|------|------|------|
| `table_type` | string | **必需**，桌型：`small`（小桌）或 `large`（大桌） |
| `people_count` | number | 人数 |
| `vip` | boolean | 是否 VIP，默认 `false` |

**响应:** `201 Created`

```json
{
  "id": "uuid",
  "number": "S0001",
  "table_type": "small",
  "vip": false,
  "people_count": 2,
  "status": "waiting",
  "created_at": "2026-06-22T18:00:00+08:00",
  "position": 0
}
```

- `number`: 叫号用的号码，小桌以 S 开头，大桌以 L 开头
- `position`: 当前前面还有几桌（0 表示马上到）

### 2. 查询排队状态 `GET /tickets/:id`

顾客用取号凭证查询自己前面还有几桌。

**响应:** `200 OK`

```json
{
  "id": "uuid",
  "number": "S0001",
  "table_type": "small",
  "vip": false,
  "people_count": 2,
  "status": "waiting",
  "created_at": "2026-06-22T18:00:00+08:00",
  "called_at": null,
  "position": 3
}
```

- `position`: 前面还有 N 桌在等待
- `status`: `waiting`（等待中）或 `called`（已叫号）

### 3. 叫号 `POST /call/next`

后厨叫下一位。

**请求体:**

```json
{
  "table_type": "small"
}
```

| 参数 | 类型 | 说明 |
|------|------|------|
| `table_type` | string | **必需**，叫哪种桌：`small` 或 `large` |

**响应:** `200 OK`

```json
{
  "id": "uuid",
  "number": "S0001",
  "table_type": "small",
  "vip": false,
  "people_count": 2,
  "status": "called",
  "created_at": "2026-06-22T18:00:00+08:00",
  "called_at": "2026-06-22T18:05:00+08:00"
}
```

如果该桌型队列为空，返回 `404 Not Found`。

### 4. 当日统计 `GET /stats/today`

查看当日排队统计和各时段高峰。

**响应:** `200 OK`

```json
{
  "date": "2026-06-22",
  "total_tickets": 45,
  "total_small": 30,
  "total_large": 15,
  "total_vip": 5,
  "total_called": 40,
  "currently_waiting": 5,
  "peak_hour": "12:00",
  "peak_hour_count": 15,
  "hourly": {
    "10:00": { "total": 2, "small": 1, "large": 1, "vip": 0, "called": 2 },
    "11:00": { "total": 8, ... },
    "12:00": { "total": 15, ... },
    ...
  }
}
```

### 5. 队列概览 `GET /queues`

查看当前各队列等待人数。

**响应:** `200 OK`

```json
{
  "small": {
    "waiting": 5,
    "vip_waiting": 1
  },
  "large": {
    "waiting": 3,
    "vip_waiting": 0
  }
}
```

## VIP 插队逻辑

- VIP 顾客取号时，会插入到所有普通顾客前面
- VIP 之间按取号先后顺序排队（先来后到）
- 叫号时优先叫 VIP，再叫普通顾客

## 运行测试

```bash
bundle exec rake test
```

## 项目结构

```
project6/
├── app.rb              # Sinatra 主应用
├── config.ru           # Rack 配置
├── Gemfile             # 依赖管理
├── Rakefile            # 任务管理
├── lib/
│   ├── ticket.rb       # 号单模型
│   └── queue_manager.rb # 队列管理器
└── test/
    └── api_test.rb     # API 测试
```
