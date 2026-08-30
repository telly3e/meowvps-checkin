#!/usr/bin/env bash
# MeowVPS 每日签到（无 Python 版本）
# 依赖：bash、curl、jq、base64；flock 可选（Debian/Ubuntu 通常随 util-linux 提供）。

set -u
set -o pipefail
umask 077

DEFAULT_BASE_URL="https://meowvps.com"
DEFAULT_ENV_FILE="/etc/meowvps-checkin.env"
DEFAULT_LOCK_FILE="/tmp/meowvps-checkin.lock"
DEFAULT_TIMEOUT=30
LAST_ERROR=""
CHECKIN_MESSAGE=""

fail() {
    LAST_ERROR="$1"
    return 1
}

load_env_file() {
    local filename="$1"
    local line key value

    [[ -f "$filename" ]] || return 0

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
    export "$plain_name"
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
    local status

    if ! status="$(curl "${CURL_OPTS[@]}" -o "$output" -w '%{http_code}' "$@")"; then
        fail "网络请求失败（curl）"
        return 1
    fi
    if [[ ! "$status" =~ ^[0-9]{3}$ ]]; then
        fail "网络请求未返回有效 HTTP 状态码"
        return 1
    fi
    if (( 10#$status < 200 || 10#$status >= 300 )); then
        fail "$(api_error_detail "$output" "$status")"
        return 1
    fi
    return 0
}

run_checkin() {
    local base_url="${MEOWVPS_BASE_URL:-$DEFAULT_BASE_URL}"
    local username password login_json
    local login_body me_body checkin_body
    local authenticated checked_in amount balance

    base_url="${base_url%/}"
    if [[ ! "$base_url" =~ ^https?://[^[:space:]]+$ ]]; then
        fail "MEOWVPS_BASE_URL 不是有效的 HTTP(S) 地址"
        return 1
    fi
    require_setting MEOWVPS_USERNAME || return 1
    require_setting MEOWVPS_PASSWORD || return 1
    username="$MEOWVPS_USERNAME"
    password="$MEOWVPS_PASSWORD"

    login_json="$(jq -nc --arg username "$username" --arg password "$password" \
        '{username:$username,password:$password}' 2>/dev/null)" || {
        fail "无法生成登录请求 JSON"
        return 1
    }

    login_body="$TMP_DIR/login.json"
    me_body="$TMP_DIR/me.json"
    checkin_body="$TMP_DIR/checkin.json"

    if ! http_json "$login_body" \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Origin: $base_url" \
        -H "Referer: $base_url/account/" \
        -X POST --data "$login_json" "$base_url/auth/login/local"; then
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

    if ! http_json "$checkin_body" \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Origin: $base_url" \
        -H "Referer: $base_url/account/" \
        -X POST --data '{}' "$base_url/auth/account/checkin"; then
        return 1
    fi

    checked_in="$(jq -r '.checkedIn // empty' "$checkin_body" 2>/dev/null || true)"
    amount="$(jq -r 'if .amount == null then "" else (.amount | tostring) end' "$checkin_body" 2>/dev/null || true)"
    balance="$(jq -r 'if .balance == null then "未知" else (.balance | tostring) end' "$checkin_body" 2>/dev/null || true)"
    if [[ "$checked_in" != true && "$checked_in" != false ]]; then
        fail "签到接口返回格式异常：缺少 checkedIn"
        return 1
    fi

    if [[ "$checked_in" == false ]]; then
        CHECKIN_MESSAGE="$(printf '🐱MeowVPS 今日已经签到\n当前余额：%s 猫币' "$balance")"
    elif [[ -n "$amount" ]] && [[ ! "$amount" =~ ^0+([.]0+)?$ ]]; then
        CHECKIN_MESSAGE="$(printf '🐱MeowVPS 签到成功\n本次获得：+%s 猫币\n当前余额：%s 猫币' "$amount" "$balance")"
    else
        CHECKIN_MESSAGE="$(printf '🐱MeowVPS 今日已经签到\n当前余额：%s 猫币' "$balance")"
    fi
    return 0
}

telegram_send() {
    local message="$1"
    local token="${TELEGRAM_BOT_TOKEN:-}"
    local chat_id="${TELEGRAM_CHAT_ID:-}"
    local api_base thread_id payload telegram_body ok description

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
    if [[ ! "$api_base" =~ ^https?://[^[:space:]]+$ ]]; then
        fail "TELEGRAM_API_BASE_URL 不是有效的 HTTP(S) 地址"
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
    if ! http_json "$telegram_body" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        --data "$payload" "$api_base/bot$token/sendMessage"; then
        LAST_ERROR="Telegram 推送失败：$LAST_ERROR"
        return 1
    fi
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

CURL_OPTS=(
    --silent --show-error --location
    --connect-timeout 10 --max-time "$TIMEOUT"
    --retry 2 --retry-delay 2
    --user-agent 'meowvps-checkin/1.0 (bash)'
)

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meowvps-checkin.XXXXXX")" || {
    echo "签到失败：无法创建临时目录。" >&2
    exit 1
}
COOKIE_FILE="$TMP_DIR/cookies.txt"
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

if ! run_checkin; then
    echo "签到失败：$LAST_ERROR" >&2
    failure_message="$(printf 'MeowVPS 签到失败\n原因：%s' "$LAST_ERROR")"
    if ! telegram_send "$failure_message"; then
        echo "Telegram 错误通知失败：$LAST_ERROR" >&2
    fi
    exit 1
fi

printf '%s\n' "$CHECKIN_MESSAGE"
if ! telegram_send "$CHECKIN_MESSAGE"; then
    echo "签到已完成，但 Telegram 通知失败：$LAST_ERROR" >&2
    exit 1
fi
