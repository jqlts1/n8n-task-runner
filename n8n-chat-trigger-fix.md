# n8n 聊天触发器配置修复指南

## 问题症状

- 使用 "When chat message received" 触发器时超时
- 聊天页面提示 "Error: Failed to receive response"
- 工作流编辑界面加载缓慢或卡顿
- 日志中出现 `X-Forwarded-For` 错误和权限错误

## 根本原因

### 1. **Webhook URL 端口配置错误**
- ❌ 错误配置：`N8N_WEBHOOK_URL=https://worker.zhangte.org/`（缺少端口）
- ✅ 正确配置：`WEBHOOK_URL=https://worker.zhangte.org:5678`（包含端口）
- **问题**：聊天触发器生成的 webhook URL 不正确，导致无法连接

### 2. **N8N_TRUST_PROXY 配置不当**
- ❌ 错误配置：`N8N_TRUST_PROXY=true`
- ✅ 正确配置：`N8N_TRUST_PROXY=loopback,linklocal,uniquelocal`
- **问题**：n8n 2.30.3 中 `true` 值无法正确处理反向代理的 X-Forwarded-For 头
- **后果**：express-rate-limit 报错，产生权限验证问题

### 3. **N8N_PORT 冲突**
- ❌ 错误尝试：设置 `N8N_PORT=5678` 或在 `N8N_HOST` 中包含端口
- **问题**：使用 `network_mode: host` 时，n8n 尝试监听 5678，但该端口已被 Nginx 占用

### 4. **超时配置不足**
- Task Runner 默认超时太短（60秒）
- Nginx proxy_connect_timeout 只有 60 秒
- 聊天工作流等待 AI 响应时会超时

## 正确配置

### docker-compose-postgres.yaml

```yaml
services:
  n8n:
    image: n8nio/n8n:2.30.3
    network_mode: host
    environment:
      # ========================================
      # 1. 监听配置：n8n 监听内部端口
      # ========================================
      - N8N_LISTEN_ADDRESS=0.0.0.0
      - N8N_PORT=5681                          # 内部端口，Nginx 反向代理到这里

      # ========================================
      # 2. 公网访问配置
      # ========================================
      - N8N_HOST=worker.zhangte.org            # 只写域名，不包含端口
      - N8N_PROTOCOL=https
      - N8N_PATH=/
      - WEBHOOK_URL=https://worker.zhangte.org:5678  # ⚠️ 必须包含外部端口 :5678
      
      # ========================================
      # 3. 反向代理配置（关键！）
      # ========================================
      - N8N_TRUST_PROXY=loopback,linklocal,uniquelocal  # ⚠️ 不能只写 true

      # ========================================
      # 4. 超时配置
      # ========================================
      - N8N_RUNNERS_TASK_TIMEOUT=600           # 10分钟（Task Runner 执行超时）
      - WEBHOOK_TIMEOUT=300000                  # 5分钟（毫秒）
      - EXECUTIONS_TIMEOUT=3600                 # 1小时（工作流执行超时）
      - EXECUTIONS_TIMEOUT_MAX=7200             # 2小时（最大超时）

      # ========================================
      # 5. WebSocket 配置
      # ========================================
      - N8N_PUSH_BACKEND=websocket
      - N8N_GRACEFUL_SHUTDOWN_TIMEOUT=30

      # ========================================
      # 6. 执行模式
      # ========================================
      - EXECUTIONS_MODE=regular                 # 聊天工作流需要

      # ========================================
      # 7. Task Runner 配置
      # ========================================
      - N8N_RUNNERS_MODE=external
      - N8N_RUNNERS_BROKER_LISTEN_ADDRESS=127.0.0.1
      - N8N_RUNNERS_AUTH_TOKEN=${N8N_RUNNERS_AUTH_TOKEN}
      - N8N_RUNNERS_MAX_CONCURRENCY=10
```

### Nginx 反向代理配置

```nginx
server {
    listen 5678 ssl;
    listen [::]:5678 ssl;
    http2 on;
    server_name worker.zhangte.org;

    # SSL 配置
    ssl_certificate    /path/to/fullchain.pem;
    ssl_certificate_key    /path/to/privkey.pem;

    location / {
        # 反向代理到 n8n 内部端口
        proxy_pass http://127.0.0.1:5681;
        proxy_http_version 1.1;

        # ========================================
        # WebSocket 支持（必须）
        # ========================================
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # ========================================
        # 代理头配置
        # ========================================
        proxy_set_header Host $host:$server_port;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # ========================================
        # 超时配置（关键！）
        # ========================================
        proxy_connect_timeout 300s;      # ⚠️ 连接超时 5分钟，不能只有 60s
        proxy_read_timeout 86400s;       # 读取超时 24小时
        proxy_send_timeout 86400s;       # 发送超时 24小时

        # ========================================
        # WebSocket 优化
        # ========================================
        proxy_buffering off;             # 防止 WebSocket 缓冲导致延迟

        # ========================================
        # 上传大小限制
        # ========================================
        client_max_body_size 128m;
    }
}
```

## 配置说明

### WEBHOOK_URL 格式

| 配置 | 是否正确 | 说明 |
|------|---------|------|
| `https://domain:5678` | ✅ | 包含非标准端口，正确 |
| `https://domain/` | ❌ | 缺少端口号 |
| `https://domain:5678/` | ⚠️ | 末尾斜杠可能导致问题，建议去掉 |

### N8N_TRUST_PROXY 值说明

n8n 2.30.3 版本中，`N8N_TRUST_PROXY` 必须设置为具体的信任范围：

- **推荐配置**：`loopback,linklocal,uniquelocal`
  - `loopback` - 信任 127.0.0.1/127.0.0.0/8, ::1/128
  - `linklocal` - 信任 169.254.0.0/16, fe80::/10
  - `uniquelocal` - 信任 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7

- **不要使用**：`true` - 会导致 express-rate-limit 错误

### 端口分离原则

使用 `network_mode: host` 时，必须分离端口：

```
外部访问 (5678) → Nginx (5678) → n8n (5681)
```

- **Nginx 监听**：5678（外部端口）
- **n8n 监听**：5681（内部端口，通过 N8N_PORT 设置）
- **不要**让 n8n 直接监听 5678

### 超时配置层级

聊天触发器的超时受三层控制：

1. **Task Runner 超时**（600秒）- 控制单个任务执行
2. **Webhook 超时**（300秒）- 控制 webhook 响应时间
3. **Nginx 连接超时**（300秒）- 控制反向代理连接

建议：Nginx 和 Webhook 超时保持一致（300秒），Task Runner 可以更长（600秒）

## 验证方法

### 1. 检查环境变量

```bash
docker exec n8n-main sh -c 'env | grep -E "(WEBHOOK|N8N_HOST|N8N_TRUST|N8N_PORT)"'
```

应该看到：
```
N8N_HOST=worker.zhangte.org
N8N_PORT=5681
WEBHOOK_URL=https://worker.zhangte.org:5678
N8N_TRUST_PROXY=loopback,linklocal,uniquelocal
```

### 2. 测试健康检查

```bash
# 测试内部端口
curl -s http://127.0.0.1:5681/healthz

# 测试外部访问
curl -s https://worker.zhangte.org:5678/healthz
```

都应该返回：`{"status":"ok"}`

### 3. 查看日志错误

```bash
docker logs n8n-main 2>&1 | grep -i "trust\|x-forwarded\|permission" | tail -20
```

如果配置正确，**不应该有**以下错误：
- ❌ `X-Forwarded-For header is set but the Express 'trust proxy' setting is false`
- ❌ `User attempted to access a workflow without permissions`

### 4. 测试聊天触发器

1. 访问工作流：`https://worker.zhangte.org:5678/workflow/{workflow_id}`
2. 打开聊天测试页面
3. 发送测试消息
4. 应该正常收到响应，不再提示 "Failed to receive response"

## 应用配置

修改 `docker-compose-postgres.yaml` 后，必须**完全重启**服务：

```bash
# 不要用 restart，要用 down + up
docker-compose -f docker-compose-postgres.yaml down
docker-compose -f docker-compose-postgres.yaml up -d
```

重启 Nginx（如果修改了 Nginx 配置）：

```bash
nginx -t && nginx -s reload
```

## 常见问题

### Q: 为什么不能用 `N8N_TRUST_PROXY=true`？

**A**: n8n 2.30.3 使用的 express-rate-limit 库对 `true` 值处理有问题。必须明确指定信任的 IP 范围。

### Q: 为什么 WEBHOOK_URL 必须包含端口号？

**A**: 聊天触发器会根据 WEBHOOK_URL 生成回调地址。如果缺少端口号，生成的 URL 会使用默认的 443 端口，导致连接失败。

### Q: 可以让 n8n 直接监听 5678 吗？

**A**: 如果使用 `network_mode: host`，并且 Nginx 已经占用 5678，n8n 无法再监听该端口。必须分离内外端口。

### Q: 超时设置多少合适？

**A**: 
- 快速响应（<30秒）：保持默认配置
- AI 聊天（可能 1-2 分钟）：建议 300 秒
- 长时间处理（数据分析等）：建议 600 秒以上

## 相关资源

- [n8n 官方文档 - 环境变量](https://docs.n8n.io/)
- [n8n GitHub Issues - Trust Proxy](https://github.com/n8n-io/n8n/issues)
- [Express Rate Limit 错误说明](https://express-rate-limit.github.io/ERR_ERL_UNEXPECTED_X_FORWARDED_FOR/)

---

**最后更新**：2026-07-13  
**适用版本**：n8n 2.30.3  
**测试环境**：Ubuntu + Nginx + Docker Compose + network_mode: host
