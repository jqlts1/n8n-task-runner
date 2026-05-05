#!/usr/bin/env bash
# 交互式部署向导：检查依赖、生成 .env、准备数据目录、可选启动 stack。
# 重复运行安全：已有的 .env 值会被保留，缺什么补什么。

set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=".env"
COMPOSE_FILE="docker-compose-postgres.yaml"

if [ -t 1 ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
    BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

log()  { printf "${BLUE}==>${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!!${RESET}  %s\n" "$*"; }
err()  { printf "${RED}xx${RESET}  %s\n" "$*" >&2; }
ok()   { printf "${GREEN}ok${RESET}  %s\n" "$*"; }

# ---------- 依赖检查 ----------
check_deps() {
    local missing=()
    command -v docker >/dev/null 2>&1 || missing+=("docker")
    if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        missing+=("docker compose v2 插件")
    fi
    command -v openssl >/dev/null 2>&1 || missing+=("openssl")
    if [ ${#missing[@]} -gt 0 ]; then
        err "缺少依赖：${missing[*]}"
        echo "    Docker 安装：https://docs.docker.com/engine/install/"
        exit 1
    fi
    ok "docker / docker compose / openssl 已就绪"
}

# ---------- 加载已有 .env ----------
load_env() {
    [ -f "$ENV_FILE" ] || return 0
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
}

# ---------- 询问一个值（已存在则回车保留） ----------
ask() {
    local prompt="$1" var="$2" current="${!2:-}" input=""
    if [ -n "$current" ]; then
        read -rp "  $prompt [当前: $current] (回车保留): " input
        [ -n "$input" ] && printf -v "$var" '%s' "$input"
    else
        while [ -z "$input" ]; do
            read -rp "  $prompt: " input
            [ -z "$input" ] && warn "不能为空"
        done
        printf -v "$var" '%s' "$input"
    fi
}

# ---------- 询问敏感值（不回显当前值） ----------
ask_secret() {
    local prompt="$1" var="$2" current="${!2:-}" input=""
    if [ -n "$current" ]; then
        read -rp "  $prompt [已配置，回车保留 / 输入新值替换]: " input
        [ -n "$input" ] && printf -v "$var" '%s' "$input"
    else
        while [ -z "$input" ]; do
            read -rp "  $prompt: " input
            [ -z "$input" ] && warn "不能为空"
        done
        printf -v "$var" '%s' "$input"
    fi
}

# ---------- 生成随机密钥 ----------
gen_secret() {
    openssl rand -base64 32 | tr -d '=+/' | cut -c1-40
}

# ---------- 准备数据目录 ----------
prepare_dirs() {
    mkdir -p ./data/n8n ./data/postgres ./data/caddy ./data/caddy-config
    # n8n 容器内是 uid=1000 的 node 用户，bind mount 必须改 owner
    if [ "$(stat -c '%u' ./data/n8n 2>/dev/null)" != "1000" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            chown -R 1000:1000 ./data/n8n
        elif command -v sudo >/dev/null 2>&1; then
            log "需要 sudo 把 ./data/n8n 改成 uid=1000（n8n 容器写入需要）"
            sudo chown -R 1000:1000 ./data/n8n
        else
            warn "./data/n8n 的 owner 不是 uid=1000，n8n 容器可能写不进去"
        fi
    fi
    ok "数据目录就绪"
}

# ---------- 主流程 ----------
main() {
    echo ""
    echo "${BOLD}n8n + Caddy HTTPS 部署向导${RESET}"
    echo ""

    check_deps
    load_env

    echo ""
    log "请填写部署参数（已有的值回车保留）"

    ask        "域名（已在 Cloudflare 托管，且 A 记录指向本机公网 IP）" DOMAIN
    ask        "ACME 注册邮箱（Let's Encrypt 续期通知发到这）"          ACME_EMAIL
    ask_secret "Cloudflare API Token（Zone:DNS:Edit 权限）"             CLOUDFLARE_API_TOKEN

    if [ -z "${POSTGRES_PASSWORD:-}" ]; then
        POSTGRES_PASSWORD=$(gen_secret)
        ok "已生成随机 Postgres 密码"
    else
        ok "复用已有 Postgres 密码（保护已有数据）"
    fi

    if [ -z "${N8N_RUNNERS_AUTH_TOKEN:-}" ]; then
        N8N_RUNNERS_AUTH_TOKEN=$(gen_secret)
        ok "已生成随机 runners auth token"
    else
        ok "复用已有 runners auth token"
    fi

    cat > "$ENV_FILE" <<EOF
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME_EMAIL
CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
N8N_RUNNERS_AUTH_TOKEN=$N8N_RUNNERS_AUTH_TOKEN
EOF
    chmod 600 "$ENV_FILE"
    ok "已写入 $ENV_FILE（权限 600）"

    prepare_dirs

    echo ""
    echo "${BOLD}启动前确认：${RESET}"
    echo "    1. Cloudflare 上 ${DOMAIN} 已经有 A 记录指向本机公网 IP"
    echo "    2. 防火墙 / 云厂商安全组 已放行 5678/tcp 入站"
    echo ""

    read -rp "现在执行 docker compose up -d --build ? [y/N] " yn
    case "$yn" in
        [Yy]*)
            local dc="docker compose -f $COMPOSE_FILE"
            if [ "$(id -u)" -ne 0 ] && ! docker info >/dev/null 2>&1; then
                dc="sudo $dc"
            fi
            $dc up -d --build
            echo ""
            ok "已启动。等首次签证书通常 30 秒以内，完成后访问："
            echo "    https://${DOMAIN}:5678"
            echo ""
            echo "看日志："
            echo "    $dc logs -f caddy"
            echo "    $dc logs -f n8n"
            ;;
        *)
            echo ""
            echo "好。手动启动："
            echo "    docker compose -f $COMPOSE_FILE up -d --build"
            ;;
    esac
}

main "$@"
