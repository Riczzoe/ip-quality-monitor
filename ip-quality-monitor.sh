#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/monitor.conf"

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ -n $TG_BOT_TOKEN && -n $TG_CHAT_ID ]] || die '请填写 monitor.conf 中的 Telegram 配置。'
[[ $STATE_DIR == /* && $STATE_DIR != / ]] || die 'STATE_DIR 必须是专用目录的绝对路径。'

validate_report() {
    jq -e -s '
      length == 1 and (.[0] |
        type == "object" and
        (.Head.IP | type == "string" and length > 0) and
        (.Head.Time | type == "string" and length > 0) and
        (.Type.Usage | type == "object" and length > 0) and
        (.Type.Company | type == "object" and length > 0) and
        (.Score | type == "object" and length > 0) and
        (.Factor | type == "object" and length > 0) and
        (.Factor | all(.[]; type == "object")) and
        (.Media | type == "object" and length > 0) and
        (.Media | all(.[]; type == "object" and has("Status")))
      )
    ' "$1" >/dev/null 2>&1
}

compare_reports() {
    jq -r -s '
      def text_value:
        if type == "string" then
          if test("^(null|true|false|-?[0-9]+(\\.[0-9]+)?)$") then @json
          else gsub("\r"; "\\r") | gsub("\n"; "\\n") end
        else tojson end;
      def fields:
        {Usage: .Type.Usage, Company: .Type.Company,
         Score: .Score, Factor: .Factor};
      def leaf_map:
        . as $root |
        reduce paths(type != "object" and type != "array") as $p
          ({}; .[($p | tojson)] =
            {path: ($p | map(tostring) | join(".")), value: ($root | getpath($p))});
      def leaf_value($m; $k):
        if $m | has($k) then $m[$k].value | text_value else "<缺失>" end;
      def media_value($m; $k):
        if ($m | has($k) | not) then "<缺失>"
        else $m[$k] as $v |
          "[" + (
            (["Status", "Region", "Type"] | map(
              . as $f | if $v | has($f) then $v[$f] | text_value else "<缺失>" end
            )) +
            (($v | keys - ["Status", "Region", "Type"]) | map(
              . as $f | $f + "=" + ($v[$f] | text_value)
            )) | join(", ")
          ) + "]"
        end;
      .[0] as $old | .[1] as $new |
      ($old | fields | leaf_map) as $a |
      ($new | fields | leaf_map) as $b |
      (
        (($a | keys) + ($b | keys) | unique[]) as $k |
        select(($a | has($k)) != ($b | has($k)) or $a[$k].value != $b[$k].value) |
        ($b[$k].path // $a[$k].path) + ": " +
          leaf_value($a; $k) + " -> " + leaf_value($b; $k)
      ),
      (
        (($old.Media | keys) + ($new.Media | keys) | unique[]) as $k |
        select(($old.Media | has($k)) != ($new.Media | has($k)) or
               $old.Media[$k] != $new.Media[$k]) |
        $k + ": " + media_value($old.Media; $k) + " -> " + media_value($new.Media; $k)
      )
    ' "$1" "$2"
}

mkdir -p -- "$STATE_DIR"
exec 9>"$STATE_DIR/.lock"
flock -n 9 || exit 0
LAST_JSON="$STATE_DIR/last.json"
WORK_DIR=$(mktemp -d "$STATE_DIR/.run.XXXXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CURRENT_JSON="$WORK_DIR/current.json"
RUN_LOG="$WORK_DIR/check.log"
DIFF_FILE="$WORK_DIR/changes.txt"

# current.json 尚不存在：上游脚本的 -o 不允许覆盖已有文件。
curl -fLsS --connect-timeout 15 --max-time 90 \
    https://IP.Check.Place -o "$WORK_DIR/ipquality.sh"
CHECK_RC=0
timeout --kill-after=30s 1800s env TERM=xterm \
    bash "$WORK_DIR/ipquality.sh" -4 -n -o "$CURRENT_JSON" >"$RUN_LOG" 2>&1 || CHECK_RC=$?
# 上游 -4 最后跳过 IPv6 的条件语句会返回 1；完整有效的 JSON 才能视为成功。
if (( CHECK_RC != 0 && CHECK_RC != 1 )); then
    cat -- "$RUN_LOG" >&2
    die "IPQuality 检测失败（退出码 $CHECK_RC），原有 last.json 保持不变。"
fi
if ! validate_report "$CURRENT_JSON"; then
    cat -- "$RUN_LOG" >&2
    die "IPQuality 未生成有效 JSON（退出码 $CHECK_RC），原有 last.json 保持不变。"
fi

if [[ -f $LAST_JSON ]]; then
    validate_report "$LAST_JSON" || die 'last.json 无效，请检查已有文件。'
    compare_reports "$LAST_JSON" "$CURRENT_JSON" >"$DIFF_FILE"
    EVENT='IP 质量变化'
else
    printf '%s\n' '首次检测：已建立比较基准。' >"$DIFF_FILE"
    EVENT='IP 质量首次检测'
fi

if [[ ! -s $DIFF_FILE ]]; then
    exit 0
fi

ARCHIVE="$STATE_DIR/$(date '+%Y-%m-%d_%H-%M-%S_%N').json"
mv -- "$CURRENT_JSON" "$ARCHIVE"
cp -- "$ARCHIVE" "$WORK_DIR/last.json"
mv -f -- "$WORK_DIR/last.json" "$LAST_JSON"

REPORT_URL=$(sed -E $'s/\033\\[[0-9;?]*[ -/]*[@-~]//g' "$RUN_LOG" |
    grep -Eio 'https://report\.check\.place/ip/[A-Za-z0-9_-]+\.svg' | tail -n 1 || true)

tg_call() {
    local method=$1
    shift
    if ! curl -sS --connect-timeout 15 --max-time 120 \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/${method}" "$@" \
        -o "$WORK_DIR/tg-response.json" 2>/dev/null; then
        printf 'Telegram %s 请求失败。\n' "$method" >&2
        return 1
    fi
    if ! jq -e '.ok == true' "$WORK_DIR/tg-response.json" >/dev/null 2>&1; then
        printf 'Telegram %s 返回失败。\n' "$method" >&2
        return 1
    fi
}

{
    printf '%s | %s\n' "$EVENT" "$(hostname)"
    jq -r '"IP: " + .Head.IP + "\n检测时间: " + .Head.Time' "$LAST_JSON"
    printf '\n'
    cat -- "$DIFF_FILE"
    [[ -z $REPORT_URL ]] || printf '\n报告: %s\n' "$REPORT_URL"
} >"$WORK_DIR/message.txt"

jq -Rs '. as $message | [range(0; ($message | length); 1800) as $start |
    $message[$start:($start + 1800)]]' "$WORK_DIR/message.txt" >"$WORK_DIR/chunks.json"
CHUNK_COUNT=$(jq 'length' "$WORK_DIR/chunks.json")
NOTICE_FAILED=0
for ((i=0; i<CHUNK_COUNT; i++)); do
    jq -j --argjson i "$i" '.[$i]' "$WORK_DIR/chunks.json" >"$WORK_DIR/chunk.txt"
    if ! tg_call sendMessage --data-urlencode "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text@$WORK_DIR/chunk.txt" \
        --data-urlencode 'link_preview_options={"is_disabled":true}'; then
        NOTICE_FAILED=1
    fi
    if ((i + 1 < CHUNK_COUNT)); then sleep 1; fi
done

if [[ -n $REPORT_URL ]] &&
    curl -fLsS --connect-timeout 15 --max-time 90 "$REPORT_URL" -o "$WORK_DIR/report.svg" &&
    grep -qi '<svg' "$WORK_DIR/report.svg"; then
    # 中文等宽字体与基线适配，避免转换后的列错位和文字覆盖背景。
    sed -e 's/font-family:[^;]*;/font-family: "WenQuanYi Zen Hei Mono", monospace;/' \
        -e 's/dominant-baseline: central;/dominant-baseline: alphabetic;/' \
        -e 's/<text /<text dy="0.35em" /g' \
        "$WORK_DIR/report.svg" >"$WORK_DIR/render.svg"
    if timeout --kill-after=5s 60s rsvg-convert --width 1600 --keep-aspect-ratio \
        --background-color '#000000' --output "$WORK_DIR/report.png" "$WORK_DIR/render.svg" &&
        [[ -s $WORK_DIR/report.png ]]; then
        if ! tg_call sendPhoto --form-string "chat_id=$TG_CHAT_ID" \
            --form "photo=@$WORK_DIR/report.png;type=image/png" \
            --form-string 'caption=本次 IP 质量检测报告'; then
            NOTICE_FAILED=1
        fi
    else
        printf '%s\n' 'SVG 转 PNG 失败。' >&2
        NOTICE_FAILED=1
    fi
else
    printf '%s\n' '本次 SVG 报告链接缺失或下载失败。' >&2
    NOTICE_FAILED=1
fi

# 通知失败不回滚基准；下次相同结果不重发。
if [[ $NOTICE_FAILED == 1 ]]; then exit 2; fi
