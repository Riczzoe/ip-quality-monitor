#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ $EUID == 0 ]] || { printf '%s\n' 'Please run sudo bash install.sh.' >&2; exit 1; }
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MONITOR_SCRIPT='ip_quality_monitor.sh'
# shellcheck source=/dev/null
source "$SOURCE_DIR/monitor.conf"

error_exit() {
    printf '%s\n' "$*" >&2
    exit 1
}
[[ -n $TG_BOT_TOKEN && -n $TG_CHAT_ID ]] || error_exit 'Please configure Telegram in monitor.conf.'
[[ $STATE_DIR == /* && $STATE_DIR != / ]] || error_exit 'STATE_DIR must be an absolute path.'
[[ ${VPS_NAME:-} =~ ^[a-zA-Z0-9_]+$ ]] || error_exit 'VPS_NAME must not be empty.'
[[ $INTERVAL_DAYS =~ ^([1-9]|[12][0-9]|3[01])$ ]] || 
    error_exit 'INTERVAL_DAYS must be an integer from 1 to 31.'
command -v apt-get >/dev/null || error_exit 'install.sh requires Debian or Ubuntu.'

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    bash curl jq bc netcat-openbsd dnsutils iproute2 util-linux coreutils cron \
    librsvg2-bin fonts-wqy-zenhei

install -d -m 700 -- "$INSTALL_DIR" "$STATE_DIR"
INSTALL_DIR=$(cd -- "$INSTALL_DIR" && pwd)
if [[ $SOURCE_DIR != "$INSTALL_DIR" ]]; then
    install -m 700 -- "$SOURCE_DIR/$MONITOR_SCRIPT" "$INSTALL_DIR/$MONITOR_SCRIPT"
    install -m 700 -- "$SOURCE_DIR/install.sh" "$INSTALL_DIR/install.sh"
    install -m 600 -- "$SOURCE_DIR/monitor.conf" "$INSTALL_DIR/monitor.conf"
else
    chmod 700 -- "$INSTALL_DIR/$MONITOR_SCRIPT" "$INSTALL_DIR/install.sh"
    chmod 600 -- "$INSTALL_DIR/monitor.conf"
fi

cat > /etc/cron.d/ip-quality-monitor <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
0 8 */$INTERVAL_DAYS * * root "$INSTALL_DIR/$MONITOR_SCRIPT" >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/ip-quality-monitor
systemctl enable --now cron
printf 'Installed: %s\nMonitor script: %s\nCron schedule: 0 8 */%s * *\n' \
    "$INSTALL_DIR" "$MONITOR_SCRIPT" "$INTERVAL_DAYS"
