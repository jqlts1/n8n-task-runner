# n8n + Task Runner 部署说明

本仓库提供两份 Docker Compose 配置，分别对应**轻量试用**和**长期使用**两种场景。两份配置都包含基于本仓库 `Dockerfile` 构建的 **task-runner**（n8n 2.x 起强烈推荐使用，承载 Code 节点的 Python/JS 执行，并预装了 ffmpeg、numpy、pandas、Pillow 等常用库）。

---

## 全新机器一键部署 HTTPS（推荐）

`docker-compose-postgres.yaml` 配套的 `setup.sh` 是一个交互式向导，自动完成：依赖检查、`.env` 生成（自动随机 secrets、缺啥补啥）、数据目录权限、可选启动。

**部署前你只需要准备 3 样东西**：

1. 一个**已托管在 Cloudflare** 的域名，且有 A 记录指向本机公网 IP（如 `worker.example.com`）
2. 一个 **Cloudflare API Token**（权限 `Zone → DNS → Edit`，建议限定到对应 zone）—— 在 https://dash.cloudflare.com/profile/api-tokens 创建
3. 防火墙 / 云厂商安全组放行 **5678/tcp** 入站（HTTPS 终止端口由 Caddy 守在这）

然后：

```bash
git clone <本仓库> && cd n8n-task-runner
./setup.sh
```

向导跑完即部署完成，访问 `https://<你的域名>:5678`。证书由 Caddy 通过 DNS-01 challenge 自动签发，无需 80/443 暴露。

> 重复运行 `setup.sh` 是安全的——已有 `.env` 里的值会自动保留，**不会重复询问**，只问缺失项。要修改某个已配置的值，直接编辑 `.env` 即可。

**升级 n8n 版本** 也用同一个脚本：改 `docker-compose-postgres.yaml` 里的 image tag（如 `n8nio/n8n:2.19.2` → `2.20.0`），然后：

```bash
./setup.sh -y    # -y 跳过启动确认，直接 docker compose up -d --build
```

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

**首次启动前还需要修一下目录权限**：n8n 容器内是用 `node` 用户（uid=1000）跑的，bind mount 的 `./data/n8n` 默认是宿主机用户所有，容器写不进去会报 `EACCES: permission denied, open '/home/node/.n8n/config'`。先执行：

```bash
mkdir -p ./data/n8n ./data/postgres
sudo chown -R 1000:1000 ./data/n8n
```

postgres 那个目录不用 chown，pg 镜像启动时会自己处理。

然后启动：

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
