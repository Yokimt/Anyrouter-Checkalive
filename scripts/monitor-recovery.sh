#!/usr/bin/env bash
# monitor-recovery.sh - Poll every Codex key on an interval, email each round,
# and exit early once everything is healthy and fast.
#
# Usage: monitor-recovery.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- Configuration ----------------------------------------------------------
BASE_URL="${CODEX_BASE_URL:-${BASE_URL:-https://anyrouter.top/v1}}"
MODEL="${CODEX_MODEL:-${MODEL:-gpt-6-astra}}"
API_STYLE="${CODEX_API_STYLE:-${API_STYLE:-auto}}"
POLL_INTERVAL="${POLL_INTERVAL:-1800}"              # 30 minutes between rounds
MAX_DURATION_SEC="${MAX_DURATION_SEC:-21500}"       # ~5h58m, under the 6h cap
FAST_THRESHOLD_SEC="${FAST_THRESHOLD_SEC:-30}"      # early-exit responsiveness bar
SLEEP_BETWEEN_TOKENS="${SLEEP_BETWEEN_TOKENS:-30}"
QQ_EMAIL="${QQ_EMAIL:-}"
QQ_SMTP_AUTH_CODE="${QQ_SMTP_AUTH_CODE:-}"

# --- Load keys --------------------------------------------------------------
if ! KEYS_DATA="$(load_keys)"; then
    die "No API keys found: set CODEX_TOKENS (one per line) or create .env from .env.example"
fi
mapfile -t KEYS < <(printf '%s\n' "$KEYS_DATA" | sed '/^[[:space:]]*$/d')
[ "${#KEYS[@]}" -gt 0 ] || die "No API keys loaded"

echo "Loaded ${#KEYS[@]} key(s)"
echo "Base URL: $BASE_URL"
echo "Model: $MODEL"
echo "API style: $API_STYLE"
echo "Poll interval: ${POLL_INTERVAL}s"
echo ""

START_TIME=$(date +%s)

# Stop promptly when cancelled from the Actions UI.
trap 'echo ""; echo "=== 收到取消信号，停止监控 ==="; exit 130' INT TERM
ROUND=1
COMPLETED_ROUNDS=0

while :; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -le 0 ]; then
        echo "=== Time limit reached. Exiting. ==="
        break
    fi

    echo "============================================="
    echo " Round $ROUND  |  $(beijing_ts)"
    echo " Elapsed: ${ELAPSED}s  |  Remaining: ~${REMAINING}s"
    echo "============================================="

    ROUND_LINES=""
    TESTED=0
    OK=0
    FAIL=0
    MAX_TIME=0
    BROKEN=false

    for i in "${!KEYS[@]}"; do
        key="${KEYS[$i]}"
        preview="${key:0:5}..."

        NOW=$(date +%s)
        if [ $((NOW - START_TIME)) -ge "$MAX_DURATION_SEC" ]; then
            echo "Time limit reached mid-round. Breaking."
            BROKEN=true
            break
        fi

        echo "[$((i + 1))/${#KEYS[@]}] Testing $preview ..."

        CHECK_START=$(date +%s)
        if bash "$SCRIPT_DIR/keepalive.sh" "$key" "$BASE_URL" "$MODEL" "$API_STYLE"; then
            RESPONSE_TIME=$(( $(date +%s) - CHECK_START ))
            TESTED=$((TESTED + 1))
            OK=$((OK + 1))
            [ "$RESPONSE_TIME" -gt "$MAX_TIME" ] && MAX_TIME=$RESPONSE_TIME
            echo "  ✓ $preview active (${RESPONSE_TIME}s)"
            ROUND_LINES+="  ✓ $preview (${RESPONSE_TIME}s)"$'\n'
        else
            TESTED=$((TESTED + 1))
            FAIL=$((FAIL + 1))
            echo "  ✗ $preview failed"
            ROUND_LINES+="  ✗ $preview failed"$'\n'
        fi

        if [ "$i" -lt "$(( ${#KEYS[@]} - 1 ))" ]; then
            JITTER=$(( SLEEP_BETWEEN_TOKENS + (RANDOM % 21) - 10 ))
            [ "$JITTER" -lt 10 ] && JITTER=10
            echo "  Waiting ${JITTER}s ..."
            sleep_seconds "$JITTER"
        fi
    done

    ROUND_SUMMARY="$ROUND_LINES"
    ROUND_SUMMARY+=$'\n'"Summary: $OK success, $FAIL failed"
    [ "$BROKEN" = true ] && ROUND_SUMMARY+=$'\n'"Note: round cut short by the run time limit (${TESTED}/${#KEYS[@]} tested)"

    echo ""
    echo "--- Round $ROUND summary: $OK success, $FAIL failed ---"
    echo ""

    COMPLETED_ROUNDS=$((COMPLETED_ROUNDS + 1))

    # --- Early exit: every key passed, nothing skipped, all fast ------------
    if [ "$BROKEN" = false ] && [ "$TESTED" -eq "${#KEYS[@]}" ] \
        && [ "$OK" -eq "${#KEYS[@]}" ] && [ "$MAX_TIME" -lt "$FAST_THRESHOLD_SEC" ]; then
        echo ">>> All keys healthy (max ${MAX_TIME}s < ${FAST_THRESHOLD_SEC}s). Sending notice and exiting."
        send_email \
            "快用！现在状态超好，不接着测了" \
            "Codex 已全面恢复，响应极快，建议立即使用！

$(beijing_ts)

各 key 状态：
$ROUND_SUMMARY

最大响应时间: ${MAX_TIME}s
所有 key 均正常工作且响应时间 < ${FAST_THRESHOLD_SEC} 秒，状态超好！检测到此结束。" || true
        echo ""
        echo "=== Early exit: all healthy and fast. ==="
        break
    fi

    # --- Regular round report ----------------------------------------------
    if [ "$FAIL" -eq 0 ] && [ "$BROKEN" = false ]; then
        send_email \
            "Codex 监控报告 - 第${ROUND}轮（全部可用）" \
            "轮次: 第 ${ROUND} 轮
检测时间: $(beijing_ts)
模型: $MODEL
接口: $BASE_URL

各 key 状态：
$ROUND_SUMMARY

最大响应时间: ${MAX_TIME}s
全部可用，但未达到 ${FAST_THRESHOLD_SEC} 秒以内的超优标准，继续监控。" || true
    else
        send_email \
            "Codex 监控报告 - 第${ROUND}轮（${FAIL}个不可用）" \
            "轮次: 第 ${ROUND} 轮
检测时间: $(beijing_ts)
模型: $MODEL
接口: $BASE_URL

各 key 状态：
$ROUND_SUMMARY

仍有 ${FAIL} 个 key 不可用，继续监控。" || true
    fi

    ROUND=$((ROUND + 1))

    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -gt "$POLL_INTERVAL" ]; then
        echo ""
        echo "--- Next round in ${POLL_INTERVAL}s ($((POLL_INTERVAL / 60)) min) ---"
        sleep_seconds "$POLL_INTERVAL"
    elif [ "$REMAINING" -gt 60 ]; then
        echo ""
        echo "--- Time nearly up, sleeping final ${REMAINING}s ---"
        sleep_seconds "$REMAINING"
    else
        echo "Time limit reached."
    fi
done

echo ""
echo "========================================"
echo " Monitor completed."
echo " Total rounds: $COMPLETED_ROUNDS"
echo "========================================"
