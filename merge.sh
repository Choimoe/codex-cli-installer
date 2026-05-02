#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SOURCE_ROOT=""
TARGET_ROOT="${HOME}/.codex"
BACKUP_ROOT=""
DRY_RUN=0
AUTO_YES=0

usage() {
  cat <<'EOF'
用法:
  merge_codex_history.sh [options]

选项:
  --source DIR         旧环境中的 Codex 根目录，通常是拷贝出来的 .codex 目录
  --target DIR         当前 Codex 根目录，默认是 ~/.codex
  --backup-root DIR    备份目录，默认是 <target>/merge_backups
  --dry-run            只打印动作，不执行写入
  -y, --yes            跳过确认，直接执行
  -h, --help           显示帮助

说明:
  1. 这个脚本只用于合并 Codex 历史，不处理业务数据库。
  2. 会先备份目标侧已有历史，再执行合并。
  3. 当前会处理:
     - history.jsonl
     - 所有 logs_*.sqlite / state_*.sqlite
     - memories/
     - sessions/
     - shell_snapshots/
  4. sqlite 合并依赖 python3 标准库 sqlite3，不要求系统安装 sqlite3 命令。
EOF
}

success() { echo -e "        ${GREEN}✓ $1${NC}"; }
warn()    { echo -e "        ${YELLOW}! $1${NC}"; }
print_err(){ echo -e "        ${RED}✗ $1${NC}"; }
info()    { echo -e "  ${CYAN}${BOLD}$1${NC}"; }

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] 错误: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

read_input() {
  local prompt="$1"
  local default="${2:-}"
  local input=""

  if [[ -n "$default" ]]; then
    echo -n "        $prompt [$default]: " >/dev/tty
  else
    echo -n "        $prompt: " >/dev/tty
  fi

  read -r input </dev/tty || true
  echo "${input:-$default}"
}

confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local answer=""

  if [[ "$AUTO_YES" -eq 1 ]]; then
    return 0
  fi

  while true; do
    answer="$(read_input "$prompt" "$default")"
    case "$answer" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) print_err "请输入 y 或 n" ;;
    esac
  done
}

abs_path() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd)
  else
    local base parent
    base="$(basename "$path")"
    parent="$(dirname "$path")"
    if [[ ! -d "$parent" ]]; then
      mkdir -p "$parent"
    fi
    parent="$(cd "$parent" && pwd)"
    printf '%s/%s\n' "$parent" "$base"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)
        SOURCE_ROOT="${2:-}"
        shift 2
        ;;
      --target)
        TARGET_ROOT="${2:-}"
        shift 2
        ;;
      --backup-root)
        BACKUP_ROOT="${2:-}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -y|--yes)
        AUTO_YES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done
}

timestamp() {
  date +%Y%m%d_%H%M%S
}

prepare_backup_root() {
  if [[ -z "$BACKUP_ROOT" ]]; then
    BACKUP_ROOT="${TARGET_ROOT}/merge_backups/$(timestamp)"
  fi
  run_cmd mkdir -p "$BACKUP_ROOT"
}

backup_if_exists() {
  local rel_path="$1"
  local src_path="${TARGET_ROOT}/${rel_path}"
  local dst_path="${BACKUP_ROOT}/${rel_path}"
  [[ -e "$src_path" ]] || return 0

  run_cmd mkdir -p "$(dirname "$dst_path")"
  log "备份目标内容: $src_path -> $dst_path"
  run_cmd cp -a "$src_path" "$dst_path"
}

ensure_python() {
  require_cmd python3
}

cleanup_sqlite_sidecars() {
  local db_path="$1"
  local shm_path="${db_path}-shm"
  local wal_path="${db_path}-wal"
  [[ -e "$shm_path" ]] && run_cmd rm -f "$shm_path"
  [[ -e "$wal_path" ]] && run_cmd rm -f "$wal_path"
}

merge_history_jsonl() {
  local source_file="${SOURCE_ROOT}/history.jsonl"
  local target_file="${TARGET_ROOT}/history.jsonl"

  [[ -f "$source_file" ]] || {
    log "未找到源 history.jsonl，跳过"
    return 0
  }

  backup_if_exists "history.jsonl"
  info "合并 history.jsonl"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "dry-run: 将去重合并 $source_file -> $target_file"
    return 0
  fi

  python3 - "$source_file" "$target_file" <<'PY'
import json
import os
import sys

source_path, target_path = sys.argv[1:3]
records = []
seen = set()

def add_line(raw: str) -> None:
    line = raw.strip()
    if not line:
        return
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        obj = None
    if obj is not None:
        key = (
            obj.get("session_id"),
            obj.get("ts"),
            obj.get("text"),
        )
    else:
        key = ("raw", line)
    if key in seen:
        return
    seen.add(key)
    records.append((obj.get("ts", 0) if obj else 0, line))

for path in (target_path, source_path):
    if not os.path.exists(path):
        continue
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            add_line(raw)

records.sort(key=lambda item: item[0])
os.makedirs(os.path.dirname(target_path), exist_ok=True)
with open(target_path, "w", encoding="utf-8") as f:
    for _, line in records:
        f.write(line)
        f.write("\n")
PY
  success "history.jsonl 合并完成"
}

merge_sqlite_pair() {
  local rel_path="$1"
  local source_db="${SOURCE_ROOT}/${rel_path}"
  local target_db="${TARGET_ROOT}/${rel_path}"

  [[ -f "$source_db" ]] || {
    log "未找到源 SQLite 文件，跳过: $rel_path"
    return 0
  }

  backup_if_exists "$rel_path"
  cleanup_sqlite_sidecars "$target_db"

  info "合并 SQLite 历史: $rel_path"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "dry-run: 将尝试逐表合并 $source_db -> $target_db"
    return 0
  fi

  python3 - "$source_db" "$target_db" <<'PY'
import os
import shutil
import sqlite3
import sys

source_db, target_db = sys.argv[1:3]

if not os.path.exists(target_db):
    os.makedirs(os.path.dirname(target_db), exist_ok=True)
    shutil.copy2(source_db, target_db)
    sys.exit(0)

src = sqlite3.connect(source_db)
dst = sqlite3.connect(target_db)
src.row_factory = sqlite3.Row

try:
    src_tables = [
        row["name"]
        for row in src.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
    ]

    for table in src_tables:
        create_sql_row = src.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
            (table,),
        ).fetchone()
        if create_sql_row is None:
            continue
        exists = dst.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            (table,),
        ).fetchone()
        if exists is None and create_sql_row["sql"]:
            dst.execute(create_sql_row["sql"])

        src_cols = [
            row["name"]
            for row in src.execute(f'PRAGMA table_info("{table}")')
        ]
        dst_cols = [
            row[1]
            for row in dst.execute(f'PRAGMA table_info("{table}")').fetchall()
        ]
        common_cols = [col for col in src_cols if col in dst_cols]
        if not common_cols:
            continue

        quoted_cols = ",".join(f'"{col}"' for col in common_cols)
        placeholders = ",".join("?" for _ in common_cols)
        insert_sql = f'INSERT OR IGNORE INTO "{table}" ({quoted_cols}) VALUES ({placeholders})'
        select_sql = f'SELECT {quoted_cols} FROM "{table}"'

        rows = src.execute(select_sql).fetchall()
        if rows:
          dst.executemany(insert_sql, [tuple(row[col] for col in common_cols) for row in rows])

    dst.commit()
finally:
    src.close()
    dst.close()
PY
  success "$rel_path 合并完成"
}

merge_tree_copy() {
  local rel_path="$1"
  local source_path="${SOURCE_ROOT}/${rel_path}"
  local target_path="${TARGET_ROOT}/${rel_path}"

  [[ -e "$source_path" ]] || {
    log "未找到源路径，跳过: $rel_path"
    return 0
  }

  backup_if_exists "$rel_path"
  run_cmd mkdir -p "$target_path"
  info "合并目录内容: $rel_path"
  run_cmd cp -an "${source_path}/." "$target_path/"
  success "$rel_path 合并完成"
}

prompt_for_paths() {
  if [[ -z "$SOURCE_ROOT" ]]; then
    echo ""
    info "请输入旧环境的 Codex 历史目录"
    echo "        一般是你从旧环境拷贝出来的 .codex 目录"
    echo ""
    SOURCE_ROOT="$(read_input "旧 Codex 目录路径")"
  fi

  if [[ -z "$TARGET_ROOT" ]]; then
    TARGET_ROOT="${HOME}/.codex"
  fi

  echo ""
  info "当前将把旧历史合并到新的 ~/.codex"
  TARGET_ROOT="$(read_input "目标 Codex 目录路径" "$TARGET_ROOT")"
}

discover_sqlite_files() {
  local source_dir="$1"
  find "$source_dir" -maxdepth 1 -type f \
    \( -name 'logs_*.sqlite' -o -name 'state_*.sqlite' \) \
    -printf '%f\n' | sort
}

print_banner() {
  echo ""
  echo -e "${BOLD}  ============================================${NC}"
  echo -e "${BOLD}    Codex 历史合并工具${NC}"
  echo -e "${BOLD}  ============================================${NC}"
  echo ""
}

main() {
  print_banner
  parse_args "$@"
  prompt_for_paths

  SOURCE_ROOT="$(abs_path "$SOURCE_ROOT")"
  TARGET_ROOT="$(abs_path "$TARGET_ROOT")"

  [[ -d "$SOURCE_ROOT" ]] || die "源目录不存在: $SOURCE_ROOT"
  if [[ ! -d "$TARGET_ROOT" ]]; then
    warn "目标目录不存在，将自动创建: $TARGET_ROOT"
    run_cmd mkdir -p "$TARGET_ROOT"
  fi

  ensure_python
  prepare_backup_root

  echo ""
  info "合并配置"
  echo "        源目录: $SOURCE_ROOT"
  echo "        目标目录: $TARGET_ROOT"
  echo "        备份目录: $BACKUP_ROOT"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "当前是 dry-run，不会写入任何内容"
  fi
  echo ""

  if ! confirm "是否继续合并?" "y"; then
    warn "用户取消合并"
    exit 0
  fi

  merge_history_jsonl

  local rel
  local found_sqlite=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    found_sqlite=1
    merge_sqlite_pair "$rel"
  done < <(discover_sqlite_files "$SOURCE_ROOT")

  if [[ "$found_sqlite" -eq 0 ]]; then
    warn "源目录中未发现 logs_*.sqlite 或 state_*.sqlite"
  fi

  for rel in memories sessions shell_snapshots; do
    merge_tree_copy "$rel"
  done

  echo ""
  success "Codex 历史合并完成"
}

main "$@"
