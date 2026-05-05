# n8n + Task Runner 部署说明

本仓库提供两份 Docker Compose 配置，分别对应**轻量试用**和**长期使用**两种场景。两份配置都包含基于本仓库 `Dockerfile` 构建的 **task-runner**（n8n 2.x 起强烈推荐使用，承载 Code 节点的 Python/JS 执行，并预装了 ffmpeg、numpy、pandas、Pillow 等常用库）。

---

## 文件总览

| 文件 | 数据库 | 数据存储 | 适用场景 |
|---|---|---|---|
| `docker-compose.yaml` | SQLite（n8n 内置） | Docker named volume | 快速试用、临时环境 |
| `docker-compose-postgres.yaml` | PostgreSQL 16 | bind mount 到 `./data/` | 长期生产、需要稳定备份 |

---

## 配置对比

| 维度 | `docker-compose.yaml` | `docker-compose-postgres.yaml` |
|---|---|---|
| 服务数量 | 2（n8n + task-runner） | 3（postgres + n8n + task-runner） |
| 数据库 | SQLite 文件，跟随 n8n 容器 | 独立的 Postgres 容器 |
| 并发能力 | 单写入，工作流多了会卡 | 支持高并发执行 |
| 数据位置 | Docker named volume `n8n_data`（藏在 `/var/lib/docker/...`） | 项目目录下的 `./data/postgres` 和 `./data/n8n` |
| 备份方式 | 需要 `docker run` 挂载 volume 后 tar | 直接 `tar` 打包 `./data/` 即可 |
| 自动重启 | ❌ | ✅ `restart: unless-stopped` |
| 健康检查 | ❌ | ✅ n8n 等 postgres 就绪后再启动 |
| 时区 | 默认 UTC | 已设为 `Asia/Shanghai` |
| task-runner | ✅ 完全相同 | ✅ 完全相同 |

---

## 快速启动

### 方案 A：SQLite 版本（轻量）

```bash
docker compose up -d --build
```

### 方案 B：Postgres 版本（推荐长期使用）

**启动前必改**：把 `docker-compose-postgres.yaml` 里两处 `n8n-pg-password-change-me` 改成同一个强密码（postgres 服务和 n8n 的 `DB_POSTGRESDB_PASSWORD` 要一致）。

```bash
docker compose -f docker-compose-postgres.yaml up -d --build
```

启动后访问 `http://localhost:5678` 或 `http://<本机IP>:5678`。

---

## task-runner 说明

两份 compose 共用同一个 `Dockerfile`，构建产物为 `n8n-runner` 容器，作为外部 task broker 客户端连接 n8n 主服务的 5679 端口。

预装内容：
- 静态 ffmpeg / ffprobe（来自 `mwader/static-ffmpeg`）
- Python 库：numpy、pandas、Pillow 等（见 `Dockerfile`）
- 自定义字体（`fonts/` 目录）
- 配置文件：`n8n-task-runners.json`

修改 `Dockerfile` 或字体后需要重新构建：

```bash
docker compose -f <对应的 compose 文件> up -d --build
```

---

## 数据备份

### SQLite 版本

```bash
docker run --rm -v n8n-task-runner_n8n_data:/data -v $(pwd):/backup alpine \
  tar -czf /backup/n8n-backup-$(date +%F).tar.gz -C /data .
```

### Postgres 版本（推荐）

**冷备**（停机，最简单）：

```bash
docker compose -f docker-compose-postgres.yaml stop
tar -czf n8n-backup-$(date +%F).tar.gz data/
docker compose -f docker-compose-postgres.yaml start
```

**热备**（不停机）：

```bash
# 备份数据库
docker exec n8n-postgres pg_dump -U n8n n8n | gzip > n8n-db-$(date +%F).sql.gz

# 同时备份 n8n 配置目录（包含凭证加密 key！）
tar -czf n8n-files-$(date +%F).tar.gz data/n8n
```

> ⚠️ **凭证加密 key 必备**：`./data/n8n/config` 文件里保存着加密 key，**丢了之后所有 credentials 都解不开**。无论用哪种备份方式，这个文件都必须一起带上。

---

## 从 SQLite 迁移到 Postgres

直接切换 compose 文件**看不到旧数据**——两套用的是不同的数据存储。要迁移：

1. 先用 SQLite 版本（`docker-compose.yaml`）启动
2. 在 n8n UI 里 **Settings → Import/Export** 把所有 workflows 和 credentials 导出为 JSON
3. `docker compose down` 关闭旧服务
4. 启动 Postgres 版本（`docker-compose-postgres.yaml`）
5. 在新 UI 里导入 JSON

---

## 端口与网络

- **5678**：n8n Web UI（已映射到宿主机）
- **5679**：task broker，仅容器内部使用，不映射出去
- **5432**：Postgres，仅容器内部使用，不映射出去（如需外部连接，自行加 `ports`）

公网/局域网访问：直接 `http://<物理机IP>:5678`，前提是防火墙放行 5678。

---

## 常用命令

```bash
# 查看服务状态
docker compose -f docker-compose-postgres.yaml ps

# 看日志
docker compose -f docker-compose-postgres.yaml logs -f n8n
docker compose -f docker-compose-postgres.yaml logs -f task-runner

# 重启单个服务
docker compose -f docker-compose-postgres.yaml restart n8n

# 停止全部（保留数据）
docker compose -f docker-compose-postgres.yaml down

# 停止 + 删除 volume（⚠️ 仅 SQLite 版本会丢数据，Postgres 版本数据在 ./data 下不受影响）
docker compose down -v
```
