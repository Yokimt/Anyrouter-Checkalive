#!/usr/bin/env bash
# set-cron.sh - Change the daily keepalive start time.
#
# GitHub cannot read variables, secrets or workflow inputs inside
# `on.schedule.cron`: the value must be a literal in the YAML. This script
# does the Beijing -> UTC conversion and edits the workflow for you.
#
# Usage: set-cron.sh HH:MM [--dry-run] [--file PATH]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<'USAGE'
Usage: scripts/set-cron.sh HH:MM [--dry-run] [--file PATH]

把 keepalive.yml 的定时启动时间改成北京时间 HH:MM（24 小时制）。
GitHub 的 cron 只认 UTC，脚本负责 -8 小时换算（可用 TZ_OFFSET_HOURS 覆盖）。

  --dry-run     只打印换算结果，不修改文件
  --file PATH   指定工作流文件（默认 .github/workflows/keepalive.yml）

示例:
  bash scripts/set-cron.sh 02:00            # → cron "0 18 * * *"
  bash scripts/set-cron.sh 07:30 --dry-run  # → cron "30 23 * * *"
USAGE
}

[ $# -ge 1 ] || { usage; exit 1; }
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

TIME="$1"
shift

FILE="${PROJECT_DIR}/.github/workflows/keepalive.yml"
DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --file)
            [ $# -ge 2 ] || die "--file 需要一个路径"
            FILE="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

if [[ ! "$TIME" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    die "时间格式应为 HH:MM（24 小时制），例如 02:00 或 18:30"
fi
HOUR=$((10#${BASH_REMATCH[1]}))
MIN=$((10#${BASH_REMATCH[2]}))
if [ "$HOUR" -gt 23 ] || [ "$MIN" -gt 59 ]; then
    die "时间超出范围: $TIME"
fi

OFFSET="${TZ_OFFSET_HOURS:-8}"
UTC_HOUR=$(( (HOUR - OFFSET) % 24 ))
if [ "$UTC_HOUR" -lt 0 ]; then
    UTC_HOUR=$(( UTC_HOUR + 24 ))
fi

CRON="$MIN $UTC_HOUR * * *"
CRON_TEXT=$(printf '%02d:%02d' "$UTC_HOUR" "$MIN")
BEIJING_TEXT=$(printf '%02d:%02d' "$HOUR" "$MIN")

if [ ! -f "$FILE" ]; then
    die "找不到工作流文件: $FILE"
fi
if ! grep -qE '^[[:space:]]*-[[:space:]]*cron:' "$FILE"; then
    die "$FILE 里没有 cron 行"
fi

COMMENT="    # keepalive-start: UTC ${CRON_TEXT} = Beijing ${BEIJING_TEXT} (edit with scripts/set-cron.sh \"HH:MM\")"
CRON_LINE="    - cron: \"$CRON\""

TMP=$(mktemp)
# shellcheck disable=SC2064
trap "rm -f '$TMP'" EXIT

awk -v comment="$COMMENT" -v cronline="$CRON_LINE" '
    /^[[:space:]]*# keepalive-start:/ { print comment; next }
    /^[[:space:]]*-[[:space:]]*cron:/ && !done { print cronline; done = 1; next }
    { print }
' "$FILE" > "$TMP"

if [ "$DRY_RUN" = true ]; then
    echo "北京时间 ${BEIJING_TEXT} 启动 → cron \"${CRON}\"（UTC ${CRON_TEXT}）"
    echo "文件未修改（--dry-run）"
    rm -f "$TMP"
    trap - EXIT
    exit 0
fi

chmod 644 "$TMP"
mv "$TMP" "$FILE"
trap - EXIT

grep -qF "cron: \"$CRON\"" "$FILE" || die "写入后校验失败，请检查 $FILE"

echo "已更新：北京时间 ${BEIJING_TEXT} 启动 → cron \"${CRON}\"（UTC ${CRON_TEXT}）"
echo "文件：$FILE"
echo ""
echo "下一步："
echo "  git diff $FILE     # 确认只改了 cron 行"
echo "  git add -A && git commit -m \"chore: keepalive start at ${BEIJING_TEXT} Beijing\" && git push"
echo "  （schedule 只认默认分支，且要到对应的 UTC 时刻才会真正触发）"
