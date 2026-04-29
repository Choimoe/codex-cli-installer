#!/usr/bin/env bash
set -euo pipefail

# ── Colors ──────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

success()   { echo -e "        ${GREEN}✓ $1${NC}"; }
print_err() { echo -e "        ${RED}✗ $1${NC}"; }
warn()      { echo -e "        ${YELLOW}! $1${NC}"; }
info()      { echo -e "  ${CYAN}${BOLD}$1${NC}"; }
step()      { echo -e "  ${CYAN}${BOLD}[$1/$2] $3${NC}"; }

# ── Prerequisites ───────────────────────────────
if ! command -v curl &>/dev/null; then
    echo -e "${RED}  ✗ 需要 curl 但未安装。请先安装 curl 后重试。${NC}"
    exit 1
fi

# ── Banner ──────────────────────────────────────
echo ""
echo -e "${BOLD}  ============================================${NC}"
echo -e "${BOLD}    Codex CLI 一键安装工具${NC}"
echo -e "${BOLD}  ============================================${NC}"
echo ""

# ── Helper functions ────────────────────────────

install_node() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &>/dev/null; then
            echo "        使用 Homebrew 安装 Node.js ..."
            brew install node
        else
            echo "        正在安装 Homebrew ..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
            # Apple Silicon PATH
            if [[ -f /opt/homebrew/bin/brew ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            fi
            brew install node
        fi
    else
        if command -v apt-get &>/dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
            sudo apt-get install -y nodejs
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y nodejs npm
        elif command -v pacman &>/dev/null; then
            sudo pacman -Sy --noconfirm nodejs npm
        else
            echo "        使用 nvm 安装 ..."
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
            export NVM_DIR="$HOME/.nvm"
            # shellcheck source=/dev/null
            [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
            nvm install --lts
        fi
    fi
}

read_input() {
    local prompt="$1"
    local default="${2:-}"
    local input=""

    if [ -n "$default" ]; then
        echo -n "        $prompt [$default]: " >/dev/tty
    else
        echo -n "        $prompt: " >/dev/tty
    fi

    read -r input </dev/tty || true
    echo "${input:-$default}"
}

read_password() {
    local prompt="$1"
    local input=""
    echo -n "        $prompt: " >/dev/tty
    read -r -s input </dev/tty || true
    echo >/dev/tty
    echo "$input"
}

normalize_url() {
    local url="$1"

    if [[ ! "$url" =~ ^https?:// ]]; then
        url="https://$url"
    fi

    if [[ "$url" != */v1 ]]; then
        if [[ "$url" == */ ]]; then
            url="${url}v1"
        else
            url="${url}/v1"
        fi
    fi

    echo "$url"
}

json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "$str"
}

read_existing_base_url() {
    local config_file="$HOME/.codex/config.toml"
    if [ -f "$config_file" ]; then
        grep -m 1 '^base_url[[:space:]]*=' "$config_file" | sed 's/^[^=]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/'
    fi
}

read_existing_api_key() {
    local auth_file="$HOME/.codex/auth.json"
    if [ -f "$auth_file" ]; then
        grep -m 1 '"OPENAI_API_KEY"' "$auth_file" | sed 's/^[^:]*:[[:space:]]*"\(.*\)"[[:space:]]*[,}][[:space:]]*$/\1/' | tr -d '\r\n'
    fi
}

prompt_api_config() {
    local raw_url=""
    local existing_base_url="$(read_existing_base_url)"
    local existing_api_key="$(read_existing_api_key)"
    local keep_existing=""

    echo ""
    echo "        请输入可用的 API 配置（将自动补全为 /v1）"
    echo ""

    if [ -n "$existing_base_url" ]; then
        echo "        当前 API 地址: $existing_base_url"
        keep_existing=$(read_input "是否保持当前地址? (y/n)" "y")
        if [[ "$keep_existing" == [Yy]* ]]; then
            BASE_URL="$existing_base_url"
        else
            while true; do
                raw_url=$(read_input "请输入 API 基础地址（例如 https://api.openai.com）")
                raw_url=$(echo "$raw_url" | tr -d '\r\n')

                if [ -z "$raw_url" ]; then
                    print_err "API 基础地址不能为空，请重新输入"
                    echo ""
                    continue
                fi

                BASE_URL=$(normalize_url "$raw_url")
                break
            done
        fi
    else
        while true; do
            raw_url=$(read_input "请输入 API 基础地址（例如 https://api.openai.com）")
            raw_url=$(echo "$raw_url" | tr -d '\r\n')

            if [ -z "$raw_url" ]; then
                print_err "API 基础地址不能为空，请重新输入"
                echo ""
                continue
            fi

            BASE_URL=$(normalize_url "$raw_url")
            break
        done
    fi

    if [ -n "$existing_api_key" ]; then
        keep_existing=$(read_input "是否保持当前 API Key? (y/n)" "y")
        if [[ "$keep_existing" == [Yy]* ]]; then
            API_KEY="$existing_api_key"
        else
            while true; do
                API_KEY=$(read_password "请输入 API Key")
                API_KEY=$(echo "$API_KEY" | tr -d '\r\n')

                if [ -z "$API_KEY" ]; then
                    print_err "API Key 不能为空，请重新输入"
                    echo ""
                    continue
                fi

                break
            done
        fi
    else
        while true; do
            API_KEY=$(read_password "请输入 API Key")
            API_KEY=$(echo "$API_KEY" | tr -d '\r\n')

            if [ -z "$API_KEY" ]; then
                print_err "API Key 不能为空，请重新输入"
                echo ""
                continue
            fi

            break
        done
    fi
}

prompt_update_mode() {
    local mode=""
    while true; do
        mode=$(read_input "检测到已安装 codex。是否覆盖配置并重置? (y/n)" "n")
        case "$mode" in
            [Yy]*) OVERWRITE_CONFIG="yes"; return ;;
            [Nn]*) OVERWRITE_CONFIG="no"; return ;;
            *)
                print_err "请输入 y 或 n"
                ;;
        esac
    done
}

write_config() {
    local base_url="$1"
    local api_key="$2"
    local codex_dir="$HOME/.codex"
    local config_file="$codex_dir/config.toml"
    local auth_file="$codex_dir/auth.json"

    mkdir -p "$codex_dir"

    cat > "$config_file" <<EOF
model = "gpt-5-codex"
model_provider = "custom"
model_reasoning_effort = "medium"
disable_response_storage = true

[model_providers.custom]
name = "custom"
base_url = "$(echo "$base_url" | sed 's/"/""/g')"
wire_api = "responses"
EOF

    cat > "$auth_file" <<EOF
{
  "OPENAI_API_KEY": "$(json_escape "$api_key")"
}
EOF

    chmod 700 "$codex_dir" 2>/dev/null || true
    chmod 600 "$config_file" "$auth_file" 2>/dev/null || true

    success "设置已写入完成"
}

write_config_existing_codex() {
    local base_url="$1"
    local api_key="$2"
    local codex_dir="$HOME/.codex"
    local config_file="$codex_dir/config.toml"
    local auth_file="$codex_dir/auth.json"

    mkdir -p "$codex_dir"

    if [ ! -s "$config_file" ]; then
        cat > "$config_file" <<EOF
model_provider = "custom"

[model_providers.custom]
name = "custom"
base_url = "$(echo "$base_url" | sed 's/"/""/g')"
wire_api = "responses"
EOF
    else
        # Keep existing user settings, only replace model_provider and [model_providers.custom].
        awk '
        BEGIN { in_custom=0; has_mp=0; did_insert=0; n=0 }

        # Drop existing [model_providers.custom] section and rewrite it later.
        /^\[model_providers\.custom\]/ || /^\[model_providers\."custom"\]/ {
            in_custom=1; next
        }
        in_custom {
            if (/^\[/) {
                in_custom=0
            } else {
                next
            }
        }

        # Replace model_provider at top level.
        /^model_provider[[:space:]]*=/ {
            buf[n++]="model_provider = \"custom\""
            has_mp=1
            next
        }

        # Insert model_provider before first section if it does not exist.
        /^\[/ && !did_insert {
            if (!has_mp) {
                buf[n++]="model_provider = \"custom\""
                has_mp=1
            }
            did_insert=1
        }

        { buf[n++]=$0 }

        END {
            if (!has_mp) {
                buf[n++]="model_provider = \"custom\""
            }

            while (n>0 && buf[n-1] ~ /^[[:space:]]*$/) n--
            for (i=0; i<n; i++) print buf[i]
            print ""
            print "[model_providers.custom]"
            print "name = \"custom\""
            print "base_url = \"__BASE_URL__\""
            print "wire_api = \"responses\""
        }
        ' "$config_file" > "${config_file}.tmp"

        sed "s|__BASE_URL__|$(echo "$base_url" | sed 's/[&|]/\\&/g; s/"/""/g')|" "${config_file}.tmp" > "${config_file}.tmp2"
        mv "${config_file}.tmp2" "$config_file"
        rm -f "${config_file}.tmp"
    fi

    cat > "$auth_file" <<EOF
{
  "OPENAI_API_KEY": "$(json_escape "$api_key")"
}
EOF

    chmod 700 "$codex_dir" 2>/dev/null || true
    chmod 600 "$config_file" "$auth_file" 2>/dev/null || true

    success "设置已写入完成"
}

# ── Detect existing installation ────────────────

if command -v codex &>/dev/null; then
    # ── Already installed: config-only mode ─────
    CODEX_VER=$(codex --version 2>/dev/null || echo "已安装")
    success "检测到 Codex CLI $CODEX_VER 已安装"
    echo ""

    step 1 3 "选择更新模式"
    prompt_update_mode
    echo ""

    step 2 3 "手动设置 API"
    prompt_api_config
    echo ""

    step 3 3 "写入设置"
    if [ "$OVERWRITE_CONFIG" = "yes" ]; then
        write_config "$BASE_URL" "$API_KEY"
    else
        write_config_existing_codex "$BASE_URL" "$API_KEY"
    fi

    # Done (config-only)
    echo ""
    echo -e "${BOLD}  ============================================${NC}"
    echo ""
    echo -e "  ${GREEN}✓ 设置完成！${NC}"
    echo ""
    echo -e "  ${YELLOW}请关闭此终端，开启新终端后输入 codex 开始使用${NC}"
    echo ""
    echo -e "${BOLD}  ============================================${NC}"
    echo ""
else
    # ── Fresh install: full flow ────────────────
    step 1 4 "检查 Node.js"

    if command -v node &>/dev/null; then
        NODE_VER=$(node -v)
        NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v//' | cut -d. -f1)
        if [ "$NODE_MAJOR" -ge 18 ]; then
            success "Node.js $NODE_VER"
        else
            print_err "Node.js $NODE_VER 版本过低（需要 v18+）"
            echo "        请更新: https://nodejs.org"
            exit 1
        fi
    else
        warn "未检测到 Node.js，正在安装..."
        install_node

        if ! command -v node &>/dev/null; then
            print_err "Node.js 安装失败，请手动安装: https://nodejs.org"
            exit 1
        fi
        success "Node.js $(node -v) 已安装"
    fi

    echo ""

    step 2 4 "安装 Codex CLI"

    npm install -g @openai/codex || {
        warn "第一次尝试失败，使用 sudo 重试..."
        sudo npm install -g @openai/codex
    }

    if command -v codex &>/dev/null; then
        CODEX_VER=$(codex --version 2>/dev/null || echo "已安装")
        success "Codex CLI $CODEX_VER"
    else
        print_err "Codex CLI 安装失败"
        exit 1
    fi

    echo ""

    step 3 4 "手动设置 API"
    prompt_api_config
    echo ""

    step 4 4 "写入设置"
    write_config "$BASE_URL" "$API_KEY"

    # Done (full install)
    echo ""
    echo -e "${BOLD}  ============================================${NC}"
    echo ""
    echo -e "  ${GREEN}✓ 安装完成！${NC}"
    echo ""
    echo -e "  ${YELLOW}请关闭此终端，开启新终端后输入 codex 开始使用${NC}"
    echo -e "  或在当前终端直接执行: ${CYAN}codex${NC}"
    echo ""
    echo -e "${BOLD}  ============================================${NC}"
    echo ""
fi
