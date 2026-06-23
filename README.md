# 餐厅排队叫号 API

基于 Ruby + Sinatra 框架开发的餐厅排队叫号系统API。

## 功能特性

- **扫码取号**：区分大桌（large）和小桌（small）
- **叫号服务**：后厨可呼叫下一位顾客
- **排队查询**：顾客通过取号凭证查询前面还有几桌
- **VIP优先**：VIP顾客自动插队到普通顾客前面
- **当日统计**：按小时统计各时段高峰情况
- **过号处理**：3次过号自动取消

## 快速开始

### 安装依赖

```bash
bundle install
```

### 启动服务

```bash
ruby app.rb
```

服务默认运行在 `http://localhost:4567`

### 运行测试

```bash
bundle exec ruby test_api.rb
```

## API 文档

### 1. 取号接口

**POST** `/api/tickets`

请求体：
```json
{
  "table_type": "small",
  "vip": false
}
```

| 参数 | 类型 | 说明 |
|------|------|------|
| table_type | string | 桌型：`small`（小桌）或 `large`（大桌） |
| vip | boolean | 是否VIP，默认 `false` |

响应示例：
```json
{
  "ticket_token": "a1b2c3d4e5f6g7h8",
  "ticket_number": 3,
  "table_type": "small",
  "vip": false,
  "position": 2,
  "created_at": "2026-06-23T12:00:00+08:00"
}
```

### 2. 查询排队状态

**GET** `/api/tickets/:token`

响应示例：
```json
{
  "ticket_token": "a1b2c3d4e5f6g7h8",
  "ticket_number": 3,
  "table_type": "small",
  "vip": false,
  "status": "waiting",
  "position": 2,
  "waiting_ahead": 1,
  "created_at": "2026-06-23T12:00:00+08:00",
  "called_at": null,
  "served_at": null
}
```

| 字段 | 说明 |
|------|------|
| status | 状态：`waiting`（等待中）、`called`（已叫号）、`served`（已就餐）、`cancelled`（已取消） |
| waiting_ahead | 前面还有几桌 |

### 3. 叫下一位（后厨端）

**POST** `/api/call-next`

请求体：
```json
{
  "table_type": "small"
}
```

响应示例：
```json
{
  "ticket_token": "a1b2c3d4e5f6g7h8",
  "ticket_number": 3,
  "table_type": "small",
  "vip": false,
  "status": "called",
  "called_at": "2026-06-23T12:05:00+08:00"
}
```

### 4. 确认就餐

**POST** `/api/tickets/:token/serve`

将已叫号的状态更新为已就餐。

### 5. 过号处理

**POST** `/api/tickets/:token/miss`

顾客未到，标记为过号。3次过号自动取消。

### 6. 队列概览

**GET** `/api/queue/:table_type`

查看当前排队人数、正在呼叫的号、下一位。

### 7. 当日统计

**GET** `/api/stats/daily`

响应示例：
```json
{
  "date": "2026-06-23",
  "total_tickets": 45,
  "table_type_stats": {
    "small": { "total": 30, "waiting": 5, "served": 25, "cancelled": 0 },
    "large": { "total": 15, "waiting": 3, "served": 12, "cancelled": 0 }
  },
  "vip_stats": { "total": 8, "served": 6 },
  "hourly_stats": {
    "0": { "small": 0, "large": 0, "vip": 0, "total": 0 },
    ...
    "12": { "small": 15, "large": 8, "vip": 3, "total": 23 },
    ...
  },
  "peak_hour": { "hour": 12, "count": 23 },
  "current_waiting": { "small": 5, "large": 3 }
}
```

### 8. 排队详情

**GET** `/api/stats/queue/:table_type`

查看完整排队列表，按VIP优先、先到先得排序。

## 数据库结构

### queue_tickets 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | integer | 主键 |
| ticket_token | string | 取号凭证（token） |
| ticket_number | integer | 叫号数字 |
| table_type | string | 桌型 |
| vip | boolean | 是否VIP |
| status | string | 状态 |
| position | integer | 当前位置 |
| miss_count | integer | 过号次数 |
| created_at | datetime | 取号时间 |
| called_at | datetime | 叫号时间 |
| served_at | datetime | 就餐时间 |

### daily_counters 表

每日按桌型独立计数，每日从1开始。

