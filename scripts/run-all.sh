#!/usr/bin/env bash
# run-all.sh - Batch Codex health-check runner with an internal 50-minute loop.
# Designed for one GitHub Actions container: runs rounds until ~5h58m, then
# emails a summary. Also usable locally (env vars or .env).
#
# Usage: run-all.sh [--once]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ONCE=false
if [ "${1:-}" = "--once" ]; then
    ONCE=true
fi

# --- Configuration ----------------------------------------------------------
BASE_URL="${CODEX_BASE_URL:-${BASE_URL:-https://anyrouter.top/v1}}"
MODEL="${CODEX_MODEL:-${MODEL:-gpt-6-astra}}"
API_STYLE="${CODEX_API_STYLE:-${API_STYLE:-auto}}"
SLEEP_BETWEEN_TOKENS="${SLEEP_BETWEEN_TOKENS:-30}"     # seconds between keys
SLEEP_BETWEEN_ROUNDS="${SLEEP_BETWEEN_ROUNDS:-3000}"   # ~50 minutes
MAX_DURATION_SEC="${MAX_DURATION_SEC:-21500}"          # ~5h58m, under the 6h cap
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
echo ""

START_TIME=$(date +%s)
ROUND=1
ALL_RESULTS=""
TOTAL_SUCCESS=0
TOTAL_FAIL=0

while :; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -le 0 ]; then
        echo "=== Time limit reached. Exiting. ==="
        break
    fi

    # Last round before the deadline: run it, then send the report with
    # everything included (the old build sent the mail one round too early).
    FINAL_ROUND=false
    if [ "$REMAINING" -le "$((SLEEP_BETWEEN_ROUNDS + 120))" ]; then
        FINAL_ROUND=true
    fi

    echo "========================================"
    echo " Round $ROUND  |  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo " Elapsed: ${ELAPSED}s  |  Remaining: ~${REMAINING}s"
    echo "========================================"

    ROUND_RESULTS=""
    ROUND_SUCCESS=0
    ROUND_FAIL=0

    for i in "${!KEYS[@]}"; do
        key="${KEYS[$i]}"
        preview="${key:0:5}..."

        NOW=$(date +%s)
        if [ $((NOW - START_TIME)) -ge "$MAX_DURATION_SEC" ]; then
            echo "Time limit reached mid-round. Breaking."
            break
        fi

        echo "[$((i + 1))/${#KEYS[@]}] Testing $preview ..."

        if bash "$SCRIPT_DIR/keepalive.sh" "$key" "$BASE_URL" "$MODEL" "$API_STYLE"; then
            echo "  ✓ $preview is active"
            ROUND_RESULTS+="  ✓ $preview active"$'\n'
            ROUND_SUCCESS=$((ROUND_SUCCESS + 1))
        else
            echo "  ✗ $preview failed"
            ROUND_RESULTS+="  ✗ $preview failed"$'\n'
            ROUND_FAIL=$((ROUND_FAIL + 1))
        fi

        if [ "$i" -lt "$(( ${#KEYS[@]} - 1 ))" ]; then
            JITTER=$(( SLEEP_BETWEEN_TOKENS + (RANDOM % 21) - 10 ))
            [ "$JITTER" -lt 10 ] && JITTER=10
            echo "  Waiting ${JITTER}s ..."
            sleep "$JITTER"
        fi
    done

    TOTAL_SUCCESS=$((TOTAL_SUCCESS + ROUND_SUCCESS))
    TOTAL_FAIL=$((TOTAL_FAIL + ROUND_FAIL))

    ALL_RESULTS+="--- Round $ROUND ($(date '+%Y-%m-%d %H:%M')) ---"$'\n'
    ALL_RESULTS+="$ROUND_RESULTS"
    ALL_RESULTS+="Round $ROUND summary: $ROUND_SUCCESS success, $ROUND_FAIL failed"$'\n'$'\n'

    echo ""
    echo "--- Round $ROUND summary: $ROUND_SUCCESS success, $ROUND_FAIL failed ---"
    echo ""

    ROUND=$((ROUND + 1))

    if [ "$ONCE" = true ]; then
        echo "=== --once mode: single round complete. Exiting. ==="
        break
    fi
    if [ "$FINAL_ROUND" = true ]; then
        echo "=== Final round complete. ==="
        break
    fi

    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -gt "$SLEEP_BETWEEN_ROUNDS" ]; then
        echo "Sleeping ${SLEEP_BETWEEN_ROUNDS}s until round $ROUND ..."
        sleep "$SLEEP_BETWEEN_ROUNDS"
    elif [ "$REMAINING" -gt 60 ]; then
        echo "Sleeping ${REMAINING}s (remaining time) ..."
        sleep "$REMAINING"
    else
        echo "Time limit reached."
    fi
done

# --- Final report -----------------------------------------------------------
SUMMARY="Rounds: $((ROUND - 1))
Total: ${TOTAL_SUCCESS} success, ${TOTAL_FAIL} failed
Model: $MODEL
Endpoint: $BASE_URL
Finished: $(beijing_ts)

$ALL_RESULTS"

echo "========================================"
echo " All rounds complete."
echo "$ALL_RESULTS"
echo "========================================"

send_email "Codex Keepalive Report ($(date '+%Y-%m-%d'))" "$SUMMARY" || true

# A run where every key failed is not a success: surface it as a red job.
if [ "$TOTAL_SUCCESS" -eq 0 ] && [ "$TOTAL_FAIL" -gt 0 ]; then
    echo "ERROR: every key failed in every round (${TOTAL_FAIL} failures)." >&2
    exit 1
fi

echo "Done."
