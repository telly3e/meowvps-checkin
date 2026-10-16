#!/usr/bin/env bash
# MeowVPS check-in installer.
# Usage: curl -fsSL https://raw.githubusercontent.com/telly3e/meowvps-checkin/main/install.sh | sudo bash

set -Eeuo pipefail
umask 077

readonly APP_DIR="/opt/meowvps-checkin"
readonly STATE_DIR="/var/lib/meowvps-checkin"
readonly CONFIG_FILE="/etc/meowvps-checkin.env"
readonly SERVICE_USER="meowvps-checkin"
readonly SERVICE_GROUP="meowvps-checkin"
readonly SERVICE_UNIT="meowvps-checkin.service"
readonly TIMER_UNIT="meowvps-checkin.timer"
readonly SERVICE_UNIT_PATH="/etc/systemd/system/$SERVICE_UNIT"
readonly TIMER_UNIT_PATH="/etc/systemd/system/$TIMER_UNIT"
readonly DEFAULT_RAW_BASE_URL="https://raw.githubusercontent.com/telly3e/meowvps-checkin/main"

RAW_BASE_URL="${MEOWVPS_RAW_BASE_URL:-$DEFAULT_RAW_BASE_URL}"
RAW_BASE_URL="${RAW_BASE_URL%/}"
TEMP_DIR=""
TIMER_SOURCE=""
TIMER_EXISTS=0
TIMER_WAS_ENABLED=0
TIMER_WAS_ACTIVE=0
SERVICE_WAS_ACTIVE=0

CFG_USERNAME=""
CFG_PASSWORD=""
CFG_TELEGRAM_TOKEN=""
CFG_TELEGRAM_CHAT_ID=""

log() {
    printf '[meowvps-checkin] %s\n' "$*"
}

die() {
    printf '[meowvps-checkin] 错误：%s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ensure_not_symlink() {
    local path="$1"
    [[ ! -L "$path" ]] || die "拒绝覆盖符号链接：$path"
}

install_runtime_dependencies() {
    local need_install=0
    local command_name

    for command_name in curl jq base64 flock useradd groupadd install awk; do
        if ! command_exists "$command_name"; then
            need_install=1
        fi
    done

    (( need_install == 0 )) && return 0

    log "正在安装运行依赖（curl、jq、base64、flock 等）……"
    if command_exists apt-get; then
        apt-get update
        apt-get install -y curl jq coreutils util-linux passwd gawk
    elif command_exists dnf; then
        dnf install -y curl jq coreutils util-linux shadow-utils gawk
    elif command_exists yum; then
        yum install -y curl jq coreutils util-linux shadow-utils gawk
    elif command_exists apk; then
        apk add --no-cache curl jq coreutils util-linux shadow gawk
    else
        die "缺少运行依赖，且未识别到 apt-get、dnf、yum 或 apk。"
    fi

    for command_name in curl jq base64 flock useradd groupadd install awk; do
        command_exists "$command_name" || die "安装依赖后仍缺少命令：$command_name"
    done
}

can_prompt() {
    [[ -r /dev/tty && -w /dev/tty ]]
}

prompt_value() {
    local prompt_text="$1"
    local output_name="$2"
    local secret="${3:-0}"
    local value

    can_prompt || return 1
    printf '%s' "$prompt_text" > /dev/tty
    if [[ "$secret" == 1 ]]; then
        IFS= read -r -s value < /dev/tty || {
            printf '\n' > /dev/tty
            return 1
        }
        printf '\n' > /dev/tty
    else
        IFS= read -r value < /dev/tty || return 1
    fi
    printf -v "$output_name" '%s' "$value"
}

prompt_yes_no() {
    local prompt_text="$1"
    local answer=""

    prompt_value "$prompt_text" answer || return 1
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

encode_b64() {
    printf '%s' "$1" | base64 | tr -d '\r\n'
}

prepare_config() {
    local password_prompted=0
    local password_confirmation=""

    if [[ -f "$CONFIG_FILE" && "${MEOWVPS_RECONFIGURE:-0}" != 1 ]]; then
        ensure_not_symlink "$CONFIG_FILE"
        chown root:root "$CONFIG_FILE"
        chmod 0600 "$CONFIG_FILE"
        log "保留现有配置：$CONFIG_FILE"
        return 0
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        ensure_not_symlink "$CONFIG_FILE"
        log "MEOWVPS_RECONFIGURE=1，准备重新写入配置。"
    fi

    CFG_USERNAME="${MEOWVPS_USERNAME:-}"
    CFG_PASSWORD="${MEOWVPS_PASSWORD:-}"
    CFG_TELEGRAM_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    CFG_TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

    if [[ -z "$CFG_USERNAME" ]]; then
        can_prompt || die "缺少 MEOWVPS_USERNAME；请在有终端的环境中运行，或通过环境变量提供配置。"
        prompt_value 'MeowVPS 用户名：' CFG_USERNAME || die "读取 MeowVPS 用户名失败。"
    fi
    [[ -n "$CFG_USERNAME" ]] || die "MeowVPS 用户名不能为空。"

    if [[ -z "$CFG_PASSWORD" ]]; then
        can_prompt || die "缺少 MEOWVPS_PASSWORD；请在有终端的环境中运行，或通过环境变量提供配置。"
        prompt_value 'MeowVPS 密码：' CFG_PASSWORD 1 || die "读取 MeowVPS 密码失败。"
        password_prompted=1
    fi
    [[ -n "$CFG_PASSWORD" ]] || die "MeowVPS 密码不能为空。"

    if (( password_prompted == 1 )); then
        prompt_value '再次输入 MeowVPS 密码：' password_confirmation 1 || die "读取密码确认失败。"
        [[ "$CFG_PASSWORD" == "$password_confirmation" ]] || die "两次输入的 MeowVPS 密码不一致。"
    fi

    if [[ -n "$CFG_TELEGRAM_TOKEN" || -n "$CFG_TELEGRAM_CHAT_ID" ]]; then
        [[ -n "$CFG_TELEGRAM_TOKEN" && -n "$CFG_TELEGRAM_CHAT_ID" ]] \
            || die "Telegram 配置不完整：需要同时提供 TELEGRAM_BOT_TOKEN 和 TELEGRAM_CHAT_ID。"
    elif [[ "${MEOWVPS_SKIP_TELEGRAM:-0}" != 1 ]] && can_prompt; then
        if prompt_yes_no '配置 Telegram Bot 通知？[y/N]：'; then
            prompt_value 'Telegram Bot Token：' CFG_TELEGRAM_TOKEN 1 \
                || die "读取 Telegram Bot Token 失败。"
            prompt_value 'Telegram Chat ID：' CFG_TELEGRAM_CHAT_ID \
                || die "读取 Telegram Chat ID 失败。"
            [[ -n "$CFG_TELEGRAM_TOKEN" && -n "$CFG_TELEGRAM_CHAT_ID" ]] \
                || die "Telegram Bot Token 和 Chat ID 不能为空。"
        fi
    fi

    local config_tmp
    config_tmp="$(mktemp "$TEMP_DIR/config.XXXXXX")"
    {
        printf '# MeowVPS check-in configuration\n'
        printf '# Credentials below are base64-encoded, not encrypted; this file must remain mode 0600.\n'
        printf 'MEOWVPS_USERNAME_B64=%s\n' "$(encode_b64 "$CFG_USERNAME")"
        printf 'MEOWVPS_PASSWORD_B64=%s\n' "$(encode_b64 "$CFG_PASSWORD")"

        if [[ -n "$CFG_TELEGRAM_TOKEN" ]]; then
            printf 'TELEGRAM_BOT_TOKEN_B64=%s\n' "$(encode_b64 "$CFG_TELEGRAM_TOKEN")"
            printf 'TELEGRAM_CHAT_ID_B64=%s\n' "$(encode_b64 "$CFG_TELEGRAM_CHAT_ID")"
        fi

        if [[ -n "${MEOWVPS_BASE_URL:-}" ]]; then
            [[ "${MEOWVPS_BASE_URL}" =~ ^https://[^[:space:]]+$ ]] \
                || die "MEOWVPS_BASE_URL 必须是 HTTPS 地址。"
            printf 'MEOWVPS_BASE_URL=%s\n' "${MEOWVPS_BASE_URL%/}"
        fi
        if [[ -n "${MEOWVPS_TIMEOUT:-}" ]]; then
            [[ "${MEOWVPS_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || die "MEOWVPS_TIMEOUT 必须是正整数。"
            printf 'MEOWVPS_TIMEOUT=%s\n' "$MEOWVPS_TIMEOUT"
        fi
        if [[ -n "${MEOWVPS_RETRY_COUNT:-}" ]]; then
            [[ "${MEOWVPS_RETRY_COUNT}" =~ ^[0-9]+$ ]] || die "MEOWVPS_RETRY_COUNT 必须是非负整数。"
            printf 'MEOWVPS_RETRY_COUNT=%s\n' "$MEOWVPS_RETRY_COUNT"
        fi
        if [[ -n "${MEOWVPS_RETRY_DELAY:-}" ]]; then
            [[ "${MEOWVPS_RETRY_DELAY}" =~ ^[0-9]+$ ]] || die "MEOWVPS_RETRY_DELAY 必须是非负整数（秒）。"
            printf 'MEOWVPS_RETRY_DELAY=%s\n' "$MEOWVPS_RETRY_DELAY"
        fi
        if [[ -n "${MEOWVPS_IP_VERSION:-}" ]]; then
            [[ "${MEOWVPS_IP_VERSION}" =~ ^(4|6|auto)$ ]] \
                || die "MEOWVPS_IP_VERSION 只能是 4、6 或 auto。"
            printf 'MEOWVPS_IP_VERSION=%s\n' "$MEOWVPS_IP_VERSION"
        fi
        if [[ -n "${TELEGRAM_API_BASE_URL:-}" ]]; then
            [[ "${TELEGRAM_API_BASE_URL}" =~ ^https://[^[:space:]]+$ ]] \
                || die "TELEGRAM_API_BASE_URL 必须是 HTTPS 地址。"
            printf 'TELEGRAM_API_BASE_URL=%s\n' "${TELEGRAM_API_BASE_URL%/}"
        fi
        if [[ -n "${TELEGRAM_MESSAGE_THREAD_ID:-}" ]]; then
            [[ "${TELEGRAM_MESSAGE_THREAD_ID}" =~ ^[0-9]+$ ]] \
                || die "TELEGRAM_MESSAGE_THREAD_ID 必须是整数。"
            printf 'TELEGRAM_MESSAGE_THREAD_ID=%s\n' "$TELEGRAM_MESSAGE_THREAD_ID"
        fi
    } > "$config_tmp"

    ensure_not_symlink "$CONFIG_FILE"
    install -o root -g root -m 0600 "$config_tmp" "$CONFIG_FILE"
    log "已写入 root-only 配置：$CONFIG_FILE"
}

ensure_service_account() {
    local nologin_shell

    if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
        groupadd --system "$SERVICE_GROUP"
    fi

    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        nologin_shell="$(command -v nologin || printf '%s' /usr/sbin/nologin)"
        useradd --system --no-create-home --home-dir /nonexistent \
            --shell "$nologin_shell" --gid "$SERVICE_GROUP" "$SERVICE_USER"
    fi
}

ensure_state_directory() {
    local state_file

    ensure_not_symlink "$STATE_DIR"
    if [[ -e "$STATE_DIR" && ! -d "$STATE_DIR" ]]; then
        die "状态目录不是目录：$STATE_DIR"
    fi
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0700 "$STATE_DIR" \
        || die "无法创建会话状态目录：$STATE_DIR"

    for state_file in "$STATE_DIR/cookies.txt" "$STATE_DIR/session-account"; do
        ensure_not_symlink "$state_file"
        if [[ -e "$state_file" && ! -f "$state_file" ]]; then
            die "会话状态文件不是普通文件：$state_file"
        fi
        if [[ -e "$state_file" ]]; then
            chown "$SERVICE_USER:$SERVICE_GROUP" "$state_file" \
                || die "无法设置会话状态文件所有者：$state_file"
            chmod 0600 "$state_file" \
                || die "无法设置会话状态文件权限：$state_file"
        fi
    done
}

download_asset() {
    local filename="$1"
    local destination="$2"

    log "下载 $filename"
    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 \
        -o "$destination" "$RAW_BASE_URL/$filename" \
        || die "下载 $filename 失败。"
    [[ -s "$destination" ]] || die "下载的 $filename 为空。"
}

extract_on_calendar() {
    local unit_file="$1"
    awk -F= '$1 == "OnCalendar" { print substr($0, index($0, "=") + 1); exit }' "$unit_file"
}

prepare_timer() {
    local template="$TEMP_DIR/meowvps-checkin.timer"
    local existing_calendar=""
    local template_calendar=""
    local selected_calendar=""
    local checkin_time="${MEOWVPS_CHECKIN_TIME:-09:00:00}"
    local timezone="${MEOWVPS_TIMEZONE:-Asia/Shanghai}"
    local generated="$TEMP_DIR/meowvps-checkin.timer.generated"

    template_calendar="$(extract_on_calendar "$template")"
    [[ -n "$template_calendar" ]] || die "远端定时器缺少 OnCalendar 配置。"

    if [[ -f "$TIMER_UNIT_PATH" ]]; then
        ensure_not_symlink "$TIMER_UNIT_PATH"
        existing_calendar="$(extract_on_calendar "$TIMER_UNIT_PATH" || true)"
    fi

    if [[ -n "${MEOWVPS_CHECKIN_TIME:-}" || -n "${MEOWVPS_TIMEZONE:-}" ]]; then
        [[ "$checkin_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$ ]] \
            || die "MEOWVPS_CHECKIN_TIME 格式应为 HH:MM 或 HH:MM:SS。"
        [[ "$timezone" =~ ^[A-Za-z0-9][A-Za-z0-9._+/-]*$ ]] \
            || die "MEOWVPS_TIMEZONE 格式异常。"
        selected_calendar="*-*-* $checkin_time $timezone"
    elif [[ -n "$existing_calendar" ]]; then
        selected_calendar="$existing_calendar"
        log "保留现有定时器时间：$selected_calendar"
    else
        selected_calendar="$template_calendar"
    fi

    systemd-analyze calendar "$selected_calendar" >/dev/null 2>&1 \
        || die "定时器日历表达式无效：$selected_calendar"

    awk -v selected_calendar="$selected_calendar" '
        /^OnCalendar=/ {
            print "OnCalendar=" selected_calendar
            replaced = 1
            next
        }
        { print }
        END {
            if (!replaced) {
                exit 2
            }
        }
    ' "$template" > "$generated" \
        || die "生成定时器文件失败。"

    TIMER_SOURCE="$generated"
}

capture_systemd_state() {
    local enabled_state=""

    ensure_not_symlink "$TIMER_UNIT_PATH"
    ensure_not_symlink "$SERVICE_UNIT_PATH"

    if [[ -e "$TIMER_UNIT_PATH" ]]; then
        TIMER_EXISTS=1
        enabled_state="$(systemctl is-enabled "$TIMER_UNIT" 2>/dev/null || true)"
        case "$enabled_state" in
            enabled|enabled-runtime|alias)
                TIMER_WAS_ENABLED=1
                ;;
        esac
        if systemctl is-active --quiet "$TIMER_UNIT"; then
            TIMER_WAS_ACTIVE=1
            systemctl stop "$TIMER_UNIT"
        fi
    fi

    if [[ -e "$SERVICE_UNIT_PATH" ]]; then
        if systemctl is-active --quiet "$SERVICE_UNIT"; then
            SERVICE_WAS_ACTIVE=1
            systemctl stop "$SERVICE_UNIT"
        fi
    fi
}

install_files() {
    ensure_not_symlink "$SERVICE_UNIT_PATH"
    ensure_not_symlink "$TIMER_UNIT_PATH"
    ensure_not_symlink "$APP_DIR"
    install -d -o root -g root -m 0755 "$APP_DIR"
    install -o root -g root -m 0755 "$TEMP_DIR/meowvps_checkin.sh" "$APP_DIR/meowvps_checkin.sh"
    install -o root -g root -m 0644 "$TEMP_DIR/meowvps-checkin.service" "$SERVICE_UNIT_PATH"
    install -o root -g root -m 0644 "$TIMER_SOURCE" "$TIMER_UNIT_PATH"
}

enable_timer() {
    systemctl daemon-reload

    if (( TIMER_EXISTS == 0 || TIMER_WAS_ENABLED == 1 || TIMER_WAS_ACTIVE == 1 )); then
        systemctl enable --now "$TIMER_UNIT"
        systemctl is-active --quiet "$TIMER_UNIT" \
            || die "定时器启用后未处于 active 状态。"
        log "定时器已启用并启动：$TIMER_UNIT"
    else
        log "保留现有定时器的禁用状态；如需启用请执行：systemctl enable --now $TIMER_UNIT"
    fi

    if (( SERVICE_WAS_ACTIVE == 1 )); then
        log "原签到服务在安装前处于 active；为避免未经确认立即签到，未自动重新运行它。"
    fi
}

main() {
    local command_name

    (( EUID == 0 )) || die "请使用 root 或 sudo 运行此安装器。"
    command_exists systemctl || die "此安装器需要 systemd（缺少 systemctl）。"
    command_exists systemd-analyze || die "此安装器需要 systemd-analyze。"

    install_runtime_dependencies

    [[ "$RAW_BASE_URL" =~ ^https://[^[:space:]]+$ ]] \
        || die "MEOWVPS_RAW_BASE_URL 必须是 HTTPS 地址。"

    TEMP_DIR="$(mktemp -d /tmp/meowvps-checkin-installer.XXXXXX)"
    prepare_config

    download_asset meowvps_checkin.sh "$TEMP_DIR/meowvps_checkin.sh"
    download_asset "$SERVICE_UNIT" "$TEMP_DIR/$SERVICE_UNIT"
    download_asset "$TIMER_UNIT" "$TEMP_DIR/$TIMER_UNIT"

    [[ "$(head -n 1 "$TEMP_DIR/meowvps_checkin.sh")" == *bash* ]] \
        || die "远端签到脚本内容校验失败。"
    bash -n "$TEMP_DIR/meowvps_checkin.sh" \
        || die "远端签到脚本语法校验失败。"
    [[ "$(head -n 1 "$TEMP_DIR/$SERVICE_UNIT")" == "[Unit]" ]] \
        || die "远端 service 文件内容校验失败。"
    [[ "$(head -n 1 "$TEMP_DIR/$TIMER_UNIT")" == "[Unit]" ]] \
        || die "远端 timer 文件内容校验失败。"

    prepare_timer
    ensure_service_account
    ensure_state_directory
    capture_systemd_state
    install_files
    enable_timer

    printf '\n'
    log "安装完成。"
    printf '配置文件：%s（仅 root 可读）\n' "$CONFIG_FILE"
    printf '安装目录：%s\n' "$APP_DIR"
    printf '会话状态：%s（仅签到服务用户可读）\n' "$STATE_DIR"
    printf '定时任务：%s\n' "$TIMER_UNIT"
    printf '\n'
    printf '立即手动签到：sudo systemctl start %s\n' "$SERVICE_UNIT"
    printf '查看定时器：sudo systemctl list-timers --all %s\n' "$TIMER_UNIT"
    printf '查看日志：sudo journalctl -u %s -n 100 --no-pager\n' "$SERVICE_UNIT"

    for command_name in curl jq base64 flock; do
        command_exists "$command_name" || die "最终检查缺少命令：$command_name"
    done
}

main "$@"
