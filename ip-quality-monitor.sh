#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/monitor.conf"

error_exit() {
    printf '%s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$STATE_DIR"
exec 9>"$STATE_DIR/.lock"
flock -n 9 || exit 0

WORK_DIR=$(mktemp -d "$STATE_DIR/.run.XXXXXXXX")
RUN_LOG="$WORK_DIR/check.log"
trap 'rm -rf -- "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CHECK_RC=0
curl -fLsS --connect-timeout 15 --max-time 90 https://IP.Check.Place -o "$WORK_DIR/ipquality.sh" \
    || error_exit 'Failed to download the IP quality checker.'
timeout --kill-after=30s 1800s env TERM=xterm bash "$WORK_DIR/ipquality.sh" -4 -n  \
    >"$RUN_LOG" 2>&1 || CHECK_RC=$?

# Upstream may return 1 after skipping IPv6.
if (( CHECK_RC != 0 && CHECK_RC != 1 )); then
    cat -- "$RUN_LOG" >&2
    error_exit "IP quality check failed (exit code: $CHECK_RC)."
fi

REPORT_URL=$(sed -E $'s/\033\\[[0-9;?]*[ -/]*[@-~]//g' "$RUN_LOG" |
    grep -Eio 'https://report\.check\.place/ip/[A-Za-z0-9_-]+\.svg' | tail -n 1 || true)
[[ -z $REPORT_URL ]] && error_exit 'No SVG report URL found.'
curl -fLsS --connect-timeout 15 --max-time 90 "$REPORT_URL" -o "$WORK_DIR/report.svg" \
    || error_exit 'Failed to download the SVG report.'

RSVG_VERSION=$(rsvg-convert --version | awk '{print $NF}')
sed -e 's/font-family:[^;}]*;/font-family: "WenQuanYi Zen Hei Mono", monospace;/' \
    -e 's/dominant-baseline: central;/dominant-baseline: alphabetic;/' \
    -e 's/<text /<text dy="0.35em" /g' \
    "$WORK_DIR/report.svg" |
    if dpkg --compare-versions "$RSVG_VERSION" lt 2.58.0; then
        awk '
        {
            while (match($0, /[0-9]+([.][0-9]+)?ch/)) {
                before = substr($0, 1, RSTART - 1)
                value = substr($0, RSTART, RLENGTH) + 0
                after = substr($0, RSTART + RLENGTH)
                $0 = before sprintf("%gem", value / 2) after
            }
            print
        }'
    else
        cat
    fi >"$WORK_DIR/render.svg"

timeout --kill-after=5s 60s rsvg-convert --width 1600 --keep-aspect-ratio \
    --background-color '#000000' --output "$WORK_DIR/report.png" "$WORK_DIR/render.svg" \
    || error_exit 'Failed to convert the SVG report to PNG.'

CAPTION=$(printf 'Server: #%s\nTime: %s\n' "$VPS_NAME" "$(date '+%Y-%m-%d %H:%M:%S %z')")
curl -sS --connect-timeout 15 --max-time 120 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendPhoto" \
    --form-string "chat_id=$TG_CHAT_ID" \
    --form "photo=@$WORK_DIR/report.png;type=image/png" \
    --form-string "caption=$CAPTION" \
    --form-string 'show_caption_above_media=true' \
    -o "$WORK_DIR/tg-response.json" \
    || error_exit 'Failed to send the Telegram request.'

jq -e '.ok == true' "$WORK_DIR/tg-response.json" >/dev/null 2>&1 \
    || error_exit 'Telegram failed to send the report.'
