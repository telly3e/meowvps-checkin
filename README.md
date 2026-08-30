# MeowVPS 自动签到

这是一个无 Python 依赖的 MeowVPS 每日签到脚本，使用 `bash`、`curl` 和 `jq` 完成登录、会话校验与签到，并通过 systemd timer 定时运行。Telegram Bot 通知是可选项。

## 一键安装

目标机器需要使用 systemd（例如 Debian 12、Ubuntu Server）。在目标 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/telly3e/meowvps-checkin/main/install.sh | sudo bash
```

首次安装时，安装器会从当前终端读取 MeowVPS 用户名和密码，并询问是否配置 Telegram Bot 通知。账号信息会写入 `/etc/meowvps-checkin.env`，文件权限为 `0600`；其中的凭据是 base64 编码，不是加密，因此不要降低文件权限或把它提交到 Git。

安装器会自动安装缺少的 `curl`、`jq`、`coreutils`、`util-linux` 等依赖，创建无登录权限的 `meowvps-checkin` 系统用户，并启用每日 09:00（`Asia/Shanghai`）运行的 timer。

## 常用操作

```bash
# 立即执行一次签到
sudo systemctl start meowvps-checkin.service

# 查看下一次运行时间
sudo systemctl list-timers --all meowvps-checkin.timer

# 查看运行日志
sudo journalctl -u meowvps-checkin.service -n 100 --no-pager

# 修改账号或通知配置后检查并手动执行
sudoedit /etc/meowvps-checkin.env
sudo systemctl start meowvps-checkin.service
```

重新执行同一条一键安装命令会更新脚本和 systemd 单元，并保留已有配置与已有定时器时间。首次安装或需要重新录入配置时，可在有终端的环境中这样运行安装器：

```bash
curl -fsSL https://raw.githubusercontent.com/telly3e/meowvps-checkin/main/install.sh | sudo env MEOWVPS_RECONFIGURE=1 bash
```

默认定时器为 `09:00:00 Asia/Shanghai`。安装时可以通过下面的方式覆盖时间；如果已有安装，安装器默认保留现有 timer 的时间。

```bash
curl -fsSL https://raw.githubusercontent.com/telly3e/meowvps-checkin/main/install.sh \
  | sudo env MEOWVPS_CHECKIN_TIME=23:30:00 MEOWVPS_TIMEZONE=Asia/Shanghai bash
```

## 文件说明

- `install.sh`：一键安装入口，适合通过 `curl | sudo bash` 执行。
- `meowvps_checkin.sh`：实际签到逻辑。
- `meowvps-checkin.service`：systemd oneshot 服务。
- `meowvps-checkin.timer`：每日定时器。

## 安全说明

- 仓库不包含用户名、密码、Telegram Bot Token、Chat ID 或 Telegram 用户账号 session 文件。
- 签到服务以 `meowvps-checkin` 非 root 用户运行，并启用 `NoNewPrivileges`、`PrivateTmp`、`ProtectSystem=strict` 和 `ProtectHome`。
- 如果 Bot Token 曾经出现在公开日志或聊天中，应立即在 BotFather 中撤销并重新生成。
