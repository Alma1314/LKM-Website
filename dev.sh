#!/usr/bin/env bash
#
# LKM 统一开发服务器启动脚本
#
# 用法：
#   ./dev.sh          # 同时启动前端(LKM-official-website)和后端(LKM-service)
#   ./dev.sh front     # 仅启动前端
#   ./dev.sh back      # 仅启动后端
#   ./dev.sh --no-run  # 仅安装依赖，不启动服务
#
# 环境变量：
#   LKM_API_KEY 前端里通过 API_URL 指向后端，默认关闭后端请求。
#   如需让前端连上本脚本启动的后端，可在运行前设置：export API_URL=http://localhost:8000
#
set -euo pipefail

# 脚本所在目录（根目录）与两个子项目路径
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$ROOT_DIR/LKM-official-website"
BACKEND_DIR="$ROOT_DIR/LKM-service"

# 默认端口
BACKEND_PORT="${BACKEND_PORT:-8000}"

log() {
  echo -e "\033[1;36m[lkm]\033[0m $*"
}

error() {
  echo -e "\033[1;31m[lkm:error]\033[0m $*" >&2
}

# 检查命令是否存在
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "未找到命令 '$cmd'，请先安装。"
    exit 1
  fi
}

install_deps() {
  local want_backend="$1"

  # 前端依赖（pnpm）
  if [ -f "$FRONTEND_DIR/package.json" ]; then
    log "安装前端依赖 (pnpm install)..."
    (cd "$FRONTEND_DIR" && pnpm install)
  else
    error "未找到 $FRONTEND_DIR/package.json，跳过前端依赖安装。"
  fi

  # 后端依赖（uv）
  if [ "$want_backend" = "yes" ] && [ -f "$BACKEND_DIR/pyproject.toml" ]; then
    log "安装后端依赖 (uv sync)..."
    (cd "$BACKEND_DIR" && uv sync)
  fi
}

run_frontend() {
  log "启动前端: pnpm run dev"
  (cd "$FRONTEND_DIR" && pnpm run dev)
}

run_backend() {
  log "启动后端: uvicorn main:app --reload --port $BACKEND_PORT"
  (cd "$BACKEND_DIR" && uv run uvicorn main:app --reload --port "$BACKEND_PORT")
}

# 仅安装依赖时
case "${1:-}" in
  --no-run)
    require_cmd pnpm
    install_deps yes
    log "依赖安装完成。"
    exit 0
    ;;
esac

require_cmd pnpm
require_cmd uv

# 确保依赖已就绪（未开启 uv 自动同步时才手动执行）
# uv sync 已存在时跳过，避免每次慢
MODE="${1:-all}"
install_deps yes

case "$MODE" in
  front|前端)
    log "前端（仅）"
    run_frontend
    ;;
  back|后端)
    log "后端（仅）"
    run_backend
    ;;
  all|*)
    log "同时启动前端与后端（Ctrl+C 可同时停止）"
    trap 'echo; log "收到退出信号，正在停止..."; kill 0 2>/dev/null' INT TERM EXIT
    run_frontend &
    run_backend &
    wait
    ;;
esac
