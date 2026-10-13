#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ $EUID == 0 ]] || { printf '%s\n' '请使用 sudo bash install.sh。' >&2; exit 1; }
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SOURCE_DIR/monitor.conf"

[[ -n $TG_BOT_TOKEN && -n $TG_CHAT_ID ]] || {
    printf '%s\n' '请先填写 monitor.conf 中的 TG_BOT_TOKEN 和 TG_CHAT_ID。' >&2
    exit 1
}
[[ $INTERVAL_DAYS =~ ^([1-9]|[12][0-9]|3[01])$ ]] || {
    printf '%s\n' 'INTERVAL_DAYS 必须是 1–31 的整数。' >&2
    exit 1
}
[[ $INSTALL_DIR == /* && $INSTALL_DIR != / && $STATE_DIR == /* && $STATE_DIR != / ]] || {
    printf '%s\n' 'INSTALL_DIR 和 STATE_DIR 必须是专用目录的绝对路径。' >&2
    exit 1
}
command -v apt-get >/dev/null || {
    printf '%s\n' 'install.sh 适用于 Debian / Ubuntu。' >&2
    exit 1
}

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    bash curl jq bc netcat-openbsd dnsutils iproute2 util-linux coreutils cron

install -d -m 700 -- "$INSTALL_DIR" "$STATE_DIR"
INSTALL_DIR=$(cd -- "$INSTALL_DIR" && pwd)
if [[ $SOURCE_DIR != "$INSTALL_DIR" ]]; then
    install -m 700 -- "$SOURCE_DIR/ip-quality-monitor.sh" "$INSTALL_DIR/ip-quality-monitor.sh"
    install -m 700 -- "$SOURCE_DIR/install.sh" "$INSTALL_DIR/install.sh"
    install -m 600 -- "$SOURCE_DIR/monitor.conf" "$INSTALL_DIR/monitor.conf"
else
    chmod 700 -- "$INSTALL_DIR/ip-quality-monitor.sh" "$INSTALL_DIR/install.sh"
    chmod 600 -- "$INSTALL_DIR/monitor.conf"
fi

# 由 cron 直接按配置启动检测脚本。
cat > /etc/cron.d/ip-quality-monitor <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
0 8 */$INTERVAL_DAYS * * root "$INSTALL_DIR/ip-quality-monitor.sh" >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/ip-quality-monitor
systemctl enable --now cron
printf '安装完成：%s\ncron 定时：0 8 */%s * *\n' "$INSTALL_DIR" "$INTERVAL_DAYS"
