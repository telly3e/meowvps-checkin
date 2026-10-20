#!/usr/bin/env bash
# MeowVPS 每日签到（无 Python 版本）
# 依赖：bash、curl、jq、base64；flock 可选（Debian/Ubuntu 通常随 util-linux 提供）。

set -u
set -o pipefail
umask 077

DEFAULT_BASE_URL="https://meowvps.com"
DEFAULT_ENV_FILE="/etc/meowvps-checkin.env"
DEFAULT_LOCK_FILE="/tmp/meowvps-checkin.lock"
DEFAULT_COOKIE_FILE="/var/lib/meowvps-checkin/cookies.txt"
DEFAULT_SESSION_ACCOUNT_FILE="/var/lib/meowvps-checkin/session-account"
DEFAULT_TIMEOUT=30
# 默认只走 IPv4，避免经由 WARP 等不稳定的 IPv6 出口导致超时。
DEFAULT_IP_VERSION=4
# 网络类失败（超时、5xx、429）时整体重试的次数与间隔（秒）。
DEFAULT_RETRY_COUNT=3
DEFAULT_RETRY_DELAY=600
TELEGRAM_ATTEMPTS=3
TELEGRAM_RETRY_DELAY=10
LAST_ERROR=""
LAST_HTTP_STATUS=""
LAST_ERROR_TRANSIENT=false
LAST_REQUEST_SENT=false
CHECKIN_MESSAGE=""
COOKIE_FILE=""
SESSION_ACCOUNT_FILE=""
CURL_OPTS=()
CURL_NO_RETRY_OPTS=()

fail() {
    LAST_ERROR="$1"
    LAST_ERROR_TRANSIENT=false
    return 1
}

load_env_file() {
    local filename="$1"
    local line key value

    [[ -f "$filename" ]] || return 0
    if [[ ! -r "$filename" ]]; then
        # systemd 已通过 EnvironmentFile 注入配置时，服务用户读不到 root-only 文件是正常的。
        if [[ -z "${MEOWVPS_USERNAME:-}${MEOWVPS_USERNAME_B64:-}" ]]; then
            echo "警告：无权读取配置文件 $filename，请使用 sudo systemctl start meowvps-checkin.service 运行。" >&2
        fi
        return 0
    fi

    # 只读取简单的 KEY=VALUE，不执行配置文件中的命令。
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        line="${line#"${line%%[![:space:]]*}"}"
        if [[ "$line" == export[[:space:]]* ]]; then
            line="${line#export }"
        fi
        [[ "$line" == *=* ]] || continue

        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:${#value}-2}"
        elif [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            value="${value:1:${#value}-2}"
        fi

        # 已经存在的环境变量优先于配置文件。
        if [[ ! -v "$key" ]]; then
            printf -v "$key" '%s' "$value"
            export "$key"
        fi
    done < "$filename"
}

decode_setting() {
    local encoded_name="$1"
    local plain_name="$2"
    local encoded decoded

    encoded="${!encoded_name:-}"
    [[ -n "$encoded" ]] || return 0
    if ! decoded="$(printf '%s' "$encoded" | base64 -d 2>/dev/null)"; then
        fail "配置项 $encoded_name 不是有效的 base64"
        return 1
    fi
    printf -v "$plain_name" '%s' "$decoded"
    return 0
}

require_setting() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        fail "缺少配置：$name"
        return 1
    fi
    return 0
}

api_error_detail() {
    local body="$1"
    local status="$2"
    local code

    code="$(jq -r 'if (.error? // .description?) then (.error // .description | tostring) else empty end' "$body" 2>/dev/null || true)"
    case "$code" in
        invalid_credentials) code="用户名或密码错误，或账户已被禁用" ;;
        login_required) code="登录状态无效，请重新登录" ;;
        too_many_requests) code="请求过于频繁，请稍后再试" ;;
        already_checked_in) code="今天已经签到" ;;
    esac
    if [[ -n "$code" ]]; then
        printf '%s（HTTP %s）' "$code" "$status"
    else
        printf 'HTTP %s' "$status"
    fi
}

http_json() {
    local output="$1"
    shift
    local status write_out request_bytes
    local -a curl_options

    curl_options=("${CURL_OPTS[@]}")
    if [[ "${1:-}" == "--no-retry" ]]; then
        curl_options=("${CURL_NO_RETRY_OPTS[@]}")
        shift
    fi

    LAST_HTTP_STATUS=""
    LAST_REQUEST_SENT=false
    if ! write_out="$(curl "${curl_options[@]}" -o "$output" -w '%{http_code} %{size_request}' "$@")"; then
        request_bytes="${write_out##* }"
        # 请求字节数为 0 说明请求从未发出（DNS、连接或 TLS 阶段失败），重试不会造成重复提交。
        if [[ "$request_bytes" =~ ^[0-9]+$ ]] && (( request_bytes > 0 )); then
            LAST_REQUEST_SENT=true
        fi
        fail "网络请求失败（curl）"
        LAST_ERROR_TRANSIENT=true
        return 1
    fi
    LAST_REQUEST_SENT=true
    status="${write_out%% *}"
    LAST_HTTP_STATUS="$status"
    if [[ ! "$status" =~ ^[0-9]{3}$ ]]; then
        fail "网络请求未返回有效 HTTP 状态码"
        return 1
    fi
    if (( 10#$status < 200 || 10#$status >= 300 )); then
        fail "$(api_error_detail "$output" "$status")"
        if (( 10#$status >= 500 || 10#$status == 429 )); then
            LAST_ERROR_TRANSIENT=true
        fi
        return 1
    fi
    return 0
}

prepare_session_files() {
    local cookie_dir account_dir session_file

    [[ "$COOKIE_FILE" == /* ]] || {
        fail "MEOWVPS_COOKIE_FILE 必须是绝对路径"
        return 1
    }
    [[ "$SESSION_ACCOUNT_FILE" == /* ]] || {
        fail "MEOWVPS_SESSION_ACCOUNT_FILE 必须是绝对路径"
        return 1
    }

    cookie_dir="${COOKIE_FILE%/*}"
    [[ -z "$cookie_dir" || "$cookie_dir" == "$COOKIE_FILE" ]] && cookie_dir="/"
    account_dir="${SESSION_ACCOUNT_FILE%/*}"
    [[ -z "$account_dir" || "$account_dir" == "$SESSION_ACCOUNT_FILE" ]] && account_dir="/"

    [[ -d "$cookie_dir" ]] || {
        fail "Cookie 目录不存在：$cookie_dir"
        return 1
    }
    [[ -d "$account_dir" ]] || {
        fail "会话账号目录不存在：$account_dir"
        return 1
    }

    for session_file in "$COOKIE_FILE" "$SESSION_ACCOUNT_FILE"; do
        [[ ! -L "$session_file" ]] || {
            fail "拒绝使用符号链接会话文件：$session_file"
            return 1
        }
        if [[ -e "$session_file" && ! -f "$session_file" ]]; then
            fail "会话路径不是普通文件：$session_file"
            return 1
        fi
    done

    if [[ ! -e "$COOKIE_FILE" ]]; then
        if ! (umask 077; : > "$COOKIE_FILE"); then
            fail "无法创建 Cookie 文件：$COOKIE_FILE"
            return 1
        fi
    fi
    chmod 0600 "$COOKIE_FILE" || {
        fail "无法设置 Cookie 文件权限：$COOKIE_FILE"
        return 1
    }
    if [[ -e "$SESSION_ACCOUNT_FILE" ]]; then
        chmod 0600 "$SESSION_ACCOUNT_FILE" || {
            fail "无法设置会话账号文件权限：$SESSION_ACCOUNT_FILE"
            return 1
        }
    fi
    return 0
}

session_account_key() {
    printf '%s' "${MEOWVPS_USERNAME:-}" | base64 | tr -d '\r\n'
}

session_account_matches() {
    local current stored

    [[ -f "$SESSION_ACCOUNT_FILE" ]] || return 1
    current="$(session_account_key)"
    stored="$(<"$SESSION_ACCOUNT_FILE")"
    [[ "$stored" == "$current" ]]
}

store_session_account() {
    local account_key account_tmp

    account_key="$(session_account_key)"
    account_tmp="$(mktemp "${SESSION_ACCOUNT_FILE}.XXXXXX")" || {
        fail "无法创建会话账号标记临时文件"
        return 1
    }
    if ! printf '%s\n' "$account_key" > "$account_tmp" \
        || ! chmod 0600 "$account_tmp" \
        || ! mv -f -- "$account_tmp" "$SESSION_ACCOUNT_FILE"; then
        rm -f -- "$account_tmp"
        fail "无法保存会话账号标记"
        return 1
    fi
    return 0
}

run_checkin() {
    local base_url="${MEOWVPS_BASE_URL:-$DEFAULT_BASE_URL}"
    local username password login_request username_file password_file
    local login_body me_body checkin_body
    local authenticated checked_in awarded amount balance checkin_balance checkin_days drop_line

    base_url="${base_url%/}"
    if [[ ! "$base_url" =~ ^https://[^[:space:]]+$ ]]; then
        fail "MEOWVPS_BASE_URL 必须是有效的 HTTPS 地址"
        return 1
    fi

    login_body="$TMP_DIR/login.json"
    me_body="$TMP_DIR/me.json"
    checkin_body="$TMP_DIR/checkin.json"

    prepare_session_files || return 1

    authenticated=false
    if [[ -s "$COOKIE_FILE" ]] && session_account_matches; then
        if http_json "$me_body" \
            -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
            -H "Accept: application/json" \
            -H "Origin: $base_url" \
            -H "Referer: $base_url/account/" \
            "$base_url/auth/me"; then
            authenticated="$(jq -r '.authenticated // false' "$me_body" 2>/dev/null || true)"
            if [[ "$authenticated" == true ]]; then
                echo "已复用现有登录会话。"
            fi
        elif [[ "$LAST_HTTP_STATUS" != 401 && "$LAST_HTTP_STATUS" != 403 ]]; then
            return 1
        fi
    fi

    if [[ "$authenticated" != true ]]; then
        require_setting MEOWVPS_USERNAME || return 1
        require_setting MEOWVPS_PASSWORD || return 1
        username="$MEOWVPS_USERNAME"
        password="$MEOWVPS_PASSWORD"

        login_request="$TMP_DIR/login.request.json"
        username_file="$TMP_DIR/login.username"
        password_file="$TMP_DIR/login.password"
        if ! printf '%s' "$username" > "$username_file" \
            || ! printf '%s' "$password" > "$password_file" \
            || ! chmod 0600 "$username_file" "$password_file"; then
            fail "无法准备登录凭据文件"
            return 1
        fi
        if ! jq -nc \
            --rawfile username "$username_file" \
            --rawfile password "$password_file" \
            '{username:$username,password:$password}' > "$login_request" 2>/dev/null; then
            fail "无法生成登录请求 JSON"
            return 1
        fi
        chmod 0600 "$login_request" || {
            fail "无法设置登录请求文件权限"
            return 1
        }

        # 不把旧账号或失效 Cookie 发送给登录接口，也避免账号切换时误用旧会话。
        : > "$COOKIE_FILE" || {
            fail "无法清理旧 Cookie 文件"
            return 1
        }
        echo "现有登录会话不存在或已失效，正在重新登录。"

        if ! http_json "$login_body" --no-retry \
            -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Origin: $base_url" \
            -H "Referer: $base_url/account/" \
            -X POST --data-binary "@$login_request" "$base_url/auth/login/local"; then
            return 1
        fi

        if ! http_json "$me_body" \
            -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
            -H "Accept: application/json" \
            -H "Origin: $base_url" \
            -H "Referer: $base_url/account/" \
            "$base_url/auth/me"; then
            return 1
        fi
        authenticated="$(jq -r '.authenticated // false' "$me_body" 2>/dev/null || true)"
        if [[ "$authenticated" != true ]]; then
            fail "登录后未取得有效会话"
            return 1
        fi
        store_session_account || return 1
    fi

    if ! http_json "$checkin_body" \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Origin: $base_url" \
        -H "Referer: $base_url/account/" \
        -X POST --data '{}' "$base_url/auth/account/checkin"; then
        return 1
    fi

    # 不能使用 `.checkedIn // empty`：jq 会把布尔值 false 当作回退条件。
    checked_in="$(jq -r 'if .checkedIn == true then "true" elif .checkedIn == false then "false" else empty end' "$checkin_body" 2>/dev/null || true)"
    # 新版接口用 awarded 标记是否掉落猫币；旧版没有该字段时按 amount 是否大于 0 判断。
    awarded="$(jq -r 'if .awarded == true then "true" elif .awarded == false then "false"
        elif ((.amount | type) == "number" and .amount > 0) then "true" else "false" end' "$checkin_body" 2>/dev/null || true)"
    amount="$(jq -r 'if .amount == null then "" else (.amount | tostring) end' "$checkin_body" 2>/dev/null || true)"
    balance="$(jq -r 'if .balance == null then "未知" else (.balance | tostring) end' "$checkin_body" 2>/dev/null || true)"
    checkin_balance="$(jq -r 'if .checkinBalance == null then "未知" else (.checkinBalance | tostring) end' "$checkin_body" 2>/dev/null || true)"
    checkin_days="$(jq -r 'if .checkinDays == null then "未知" else (.checkinDays | tostring) + " 天" end' "$checkin_body" 2>/dev/null || true)"
    if [[ "$checked_in" != true && "$checked_in" != false ]]; then
        fail "签到接口返回格式异常：缺少 checkedIn"
        return 1
    fi

    if [[ "$checked_in" == false ]]; then
        CHECKIN_MESSAGE="$(printf '🐱MeowVPS 今日已经签到\n当前猫币：%s\n当前签到数：%s\n累计签到：%s' \
            "$balance" "$checkin_balance" "$checkin_days")"
        return 0
    fi

    if [[ "$awarded" == true ]]; then
        if [[ -n "$amount" && ! "$amount" =~ ^0+([.]0+)?$ ]]; then
            drop_line="🎉 掉落猫币：+$amount"
        else
            drop_line="🎉 掉落了猫币"
        fi
    else
        drop_line="本次未掉落猫币"
    fi
    CHECKIN_MESSAGE="$(printf '🐱MeowVPS 签到成功\n%s\n当前猫币：%s\n当前签到数：%s\n累计签到：%s' \
        "$drop_line" "$balance" "$checkin_balance" "$checkin_days")"
    return 0
}

telegram_send() {
    local message="$1"
    local token="${TELEGRAM_BOT_TOKEN:-}"
    local chat_id="${TELEGRAM_CHAT_ID:-}"
    local api_base thread_id payload telegram_body telegram_payload_file telegram_url_file ok description attempt

    if [[ -z "$token" && -z "$chat_id" ]]; then
        echo "未配置 Telegram，跳过通知。"
        return 0
    fi
    if [[ -z "$token" || -z "$chat_id" ]]; then
        fail "Telegram 配置不完整：需要 TELEGRAM_BOT_TOKEN 和 TELEGRAM_CHAT_ID"
        return 1
    fi
    if [[ ! "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        fail "TELEGRAM_BOT_TOKEN 格式异常"
        return 1
    fi

    api_base="${TELEGRAM_API_BASE_URL:-https://api.telegram.org}"
    api_base="${api_base%/}"
    if [[ ! "$api_base" =~ ^https://[^[:space:]]+$ \
        || "$api_base" == *'"'* || "$api_base" == *'\'* ]]; then
        fail "TELEGRAM_API_BASE_URL 必须是有效的 HTTPS 地址"
        return 1
    fi

    thread_id="${TELEGRAM_MESSAGE_THREAD_ID:-}"
    if [[ -n "$thread_id" && ! "$thread_id" =~ ^[0-9]+$ ]]; then
        fail "TELEGRAM_MESSAGE_THREAD_ID 必须是整数"
        return 1
    fi
    if ! payload="$(jq -nc --arg chat_id "$chat_id" --arg text "$message" --arg thread "$thread_id" \
        '{chat_id:$chat_id,text:$text,disable_web_page_preview:true} +
         (if $thread == "" then {} else {message_thread_id:($thread|tonumber)} end)' 2>/dev/null)"; then
        fail "无法生成 Telegram 请求 JSON"
        return 1
    fi

    telegram_body="$TMP_DIR/telegram.json"
    telegram_payload_file="$TMP_DIR/telegram.request.json"
    telegram_url_file="$TMP_DIR/telegram.url.conf"
    if ! printf '%s' "$payload" > "$telegram_payload_file" \
        || ! printf 'url = "%s/bot%s/sendMessage"\n' "$api_base" "$token" > "$telegram_url_file" \
        || ! chmod 0600 "$telegram_payload_file" "$telegram_url_file"; then
        fail "无法准备 Telegram 请求文件"
        return 1
    fi
    # 只在请求确定没有发出时重试，避免 Telegram 收到重复消息。
    attempt=1
    while ! http_json "$telegram_body" --no-retry \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        --data-binary "@$telegram_payload_file" \
        --config "$telegram_url_file"; do
        if [[ "$LAST_REQUEST_SENT" == false ]] && (( attempt < TELEGRAM_ATTEMPTS )); then
            echo "Telegram 连接失败，${TELEGRAM_RETRY_DELAY} 秒后重试（第 $attempt/$TELEGRAM_ATTEMPTS 次）。" >&2
            sleep "$TELEGRAM_RETRY_DELAY"
            attempt=$((attempt + 1))
            continue
        fi
        LAST_ERROR="Telegram 推送失败：$LAST_ERROR"
        return 1
    done
    ok="$(jq -r '.ok // false' "$telegram_body" 2>/dev/null || true)"
    if [[ "$ok" != true ]]; then
        description="$(jq -r '.description // "接口返回格式异常"' "$telegram_body" 2>/dev/null || true)"
        fail "Telegram 推送失败：$description"
        return 1
    fi
    echo "Telegram 通知已发送。"
    return 0
}

ENV_FILE="${MEOWVPS_ENV_FILE:-$DEFAULT_ENV_FILE}"
load_env_file "$ENV_FILE"
decode_setting MEOWVPS_USERNAME_B64 MEOWVPS_USERNAME || {
    echo "签到失败：$LAST_ERROR" >&2
    exit 1
}
decode_setting MEOWVPS_PASSWORD_B64 MEOWVPS_PASSWORD || {
    echo "签到失败：$LAST_ERROR" >&2
    exit 1
}
decode_setting TELEGRAM_BOT_TOKEN_B64 TELEGRAM_BOT_TOKEN || {
    echo "签到失败：$LAST_ERROR" >&2
    exit 1
}
decode_setting TELEGRAM_CHAT_ID_B64 TELEGRAM_CHAT_ID || {
    echo "签到失败：$LAST_ERROR" >&2
    exit 1
}

if ! command -v curl >/dev/null 2>&1; then
    echo "签到失败：缺少 curl，请先安装。" >&2
    exit 1
fi
if ! command -v base64 >/dev/null 2>&1; then
    echo "签到失败：缺少 base64，请先安装 coreutils。" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "签到失败：缺少 jq，请先安装。" >&2
    exit 1
fi

TIMEOUT="${MEOWVPS_TIMEOUT:-$DEFAULT_TIMEOUT}"
if [[ ! "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    echo "签到失败：MEOWVPS_TIMEOUT 必须是正整数。" >&2
    exit 1
fi

RETRY_COUNT="${MEOWVPS_RETRY_COUNT:-$DEFAULT_RETRY_COUNT}"
if [[ ! "$RETRY_COUNT" =~ ^[0-9]+$ ]]; then
    echo "签到失败：MEOWVPS_RETRY_COUNT 必须是非负整数。" >&2
    exit 1
fi
RETRY_COUNT=$((10#$RETRY_COUNT))
RETRY_DELAY="${MEOWVPS_RETRY_DELAY:-$DEFAULT_RETRY_DELAY}"
if [[ ! "$RETRY_DELAY" =~ ^[0-9]+$ ]]; then
    echo "签到失败：MEOWVPS_RETRY_DELAY 必须是非负整数（秒）。" >&2
    exit 1
fi

IP_VERSION="${MEOWVPS_IP_VERSION:-$DEFAULT_IP_VERSION}"
case "$IP_VERSION" in
    4) IP_OPTS=(--ipv4) ;;
    6) IP_OPTS=(--ipv6) ;;
    auto) IP_OPTS=() ;;
    *)
        echo "签到失败：MEOWVPS_IP_VERSION 只能是 4、6 或 auto。" >&2
        exit 1
        ;;
esac

CURL_OPTS=(
    --silent --show-error --location
    --connect-timeout 10 --max-time "$TIMEOUT"
    --retry 2 --retry-delay 2
    "${IP_OPTS[@]}"
    --proto '=https' --proto-redir '=https'
    --user-agent 'meowvps-checkin/1.0 (bash)'
)
CURL_NO_RETRY_OPTS=(
    --silent --show-error --location
    --connect-timeout 10 --max-time "$TIMEOUT"
    "${IP_OPTS[@]}"
    --proto '=https' --proto-redir '=https'
    --user-agent 'meowvps-checkin/1.0 (bash)'
)

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meowvps-checkin.XXXXXX")" || {
    echo "签到失败：无法创建临时目录。" >&2
    exit 1
}
COOKIE_FILE="${MEOWVPS_COOKIE_FILE:-$DEFAULT_COOKIE_FILE}"
SESSION_ACCOUNT_FILE="${MEOWVPS_SESSION_ACCOUNT_FILE:-$DEFAULT_SESSION_ACCOUNT_FILE}"
trap 'rm -rf -- "$TMP_DIR"' EXIT

LOCK_FILE="${MEOWVPS_LOCK_FILE:-$DEFAULT_LOCK_FILE}"
LOCK_DIR="${LOCK_FILE%/*}"
[[ "$LOCK_DIR" == "$LOCK_FILE" ]] && LOCK_DIR="."
if ! mkdir -p -- "$LOCK_DIR"; then
    echo "签到失败：无法创建锁文件目录。" >&2
    exit 1
fi
if ! exec 9>"$LOCK_FILE"; then
    echo "签到失败：无法打开锁文件。" >&2
    exit 1
fi
if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
        echo "已有一个签到任务正在运行，本次跳过。"
        exit 0
    fi
else
    echo "警告：未找到 flock，将不启用重复运行锁。" >&2
fi

attempt=1
while ! run_checkin; do
    if [[ "$LAST_ERROR_TRANSIENT" == true ]] && (( attempt <= RETRY_COUNT )); then
        echo "签到失败：$LAST_ERROR；${RETRY_DELAY} 秒后重试（第 $attempt/$RETRY_COUNT 次重试）。" >&2
        sleep "$RETRY_DELAY"
        attempt=$((attempt + 1))
        continue
    fi
    if (( attempt > 1 )); then
        LAST_ERROR="$LAST_ERROR（已重试 $((attempt - 1)) 次）"
    fi
    echo "签到失败：$LAST_ERROR" >&2
    failure_message="$(printf 'MeowVPS 签到失败\n原因：%s' "$LAST_ERROR")"
    if ! telegram_send "$failure_message"; then
        echo "Telegram 错误通知失败：$LAST_ERROR" >&2
    fi
    exit 1
done

printf '%s\n' "$CHECKIN_MESSAGE"
if ! telegram_send "$CHECKIN_MESSAGE"; then
    echo "签到已完成，但 Telegram 通知失败：$LAST_ERROR" >&2
    exit 1
fi
