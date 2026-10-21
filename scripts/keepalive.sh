#!/usr/bin/env bash
# keepalive.sh - Health-check a single Codex API key against a Codex-compatible
# endpoint (Responses API by default, Chat Completions as a fallback).
#
# Usage: keepalive.sh <api-key> [base_url] [model] [api_style]
#
# The request shape mirrors the reference client (codex_keepalive_v20):
#   POST {base_url}/v1/responses with Bearer auth, Codex Desktop identity,
#   session-id / thread-id headers, store=false and a short prompt.
# Prints everything (request metadata, HTTP status, answer, error) so failures
# can be diagnosed from the Actions log alone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

KEY="${1:?Usage: $0 <api-key> [base_url] [model] [api_style]}"
BASE_URL="${2:-${BASE_URL:-https://anyrouter.top/v1}}"
MODEL="${3:-${MODEL:-gpt-6-astra}}"
API_STYLE_ARG="${4:-${API_STYLE:-auto}}"

REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-90}"
MAX_OUTPUT_TOKENS="${MAX_OUTPUT_TOKENS:-128}"
REASONING_EFFORT="${REASONING_EFFORT:-low}"
STREAM="${STREAM:-1}"
ORIGINATOR="${ORIGINATOR:-Codex Desktop}"
USER_AGENT="${USER_AGENT:-Codex Desktop (codex-keepalive/1.0)}"
INSTRUCTION="${CODEX_INSTRUCTION:-回答下面的问题。直接给出结论，回答尽量简短；不要调用工具、不要写文件、不要访问网络。}"

if [ "$STREAM" = "1" ] || [ "$STREAM" = "true" ]; then
    STREAM_JSON=true
    ACCEPT="text/event-stream"
else
    STREAM_JSON=false
    ACCEPT="application/json"
fi

PROMPT="${PROMPT:-$(pick_prompt "$SCRIPT_DIR/prompts.txt")}"
SESSION_ID="${SESSION_ID:-$(new_uuid)}"

resolve_endpoint "$BASE_URL" "$API_STYLE_ARG"   # -> EP_STYLE, EP_URL

TMP_DIR=$(mktemp -d)
chmod 700 "$TMP_DIR"
# shellcheck disable=SC2064
trap "rm -rf '$TMP_DIR'" EXIT

# --- Build the request body -------------------------------------------------
build_body() {
    local body
    if [ "$EP_STYLE" = "chat" ]; then
        local token_param="${CHAT_TOKEN_PARAM:-auto}"
        if [ "$token_param" = "auto" ]; then
            case "${MODEL,,}" in
                gpt-5*|gpt-6*) token_param="max_completion_tokens" ;;
                *) token_param="max_tokens" ;;
            esac
        fi
        body=$(jq -n --arg m "$MODEL" --arg s "$INSTRUCTION" --arg u "$PROMPT" \
                     --argjson stream "$STREAM_JSON" --argjson max "$MAX_OUTPUT_TOKENS" \
                     --arg tp "$token_param" \
            '{model: $m,
              messages: [{role: "system", content: $s}, {role: "user", content: $u}],
              stream: $stream}
             + {($tp): $max}')
    else
        body=$(jq -n --arg m "$MODEL" --arg s "$INSTRUCTION" --arg u "$PROMPT" \
                     --argjson stream "$STREAM_JSON" --argjson max "$MAX_OUTPUT_TOKENS" \
                     --arg sid "$SESSION_ID" \
            '{model: $m,
              stream: $stream,
              store: false,
              instructions: $s,
              input: [{type: "message", role: "user",
                       content: [{type: "input_text", text: $u}]}],
              max_output_tokens: $max,
              prompt_cache_key: $sid}')
        if [ -n "$REASONING_EFFORT" ]; then
            case "${MODEL,,}" in
                gpt-5*|gpt-6*)
                    body=$(printf '%s' "$body" | jq --arg e "$REASONING_EFFORT" \
                        '. + {reasoning: {effort: $e}, text: {verbosity: "low"}}')
                    ;;
            esac
        fi
    fi
    printf '%s' "$body"
}

build_body > "$TMP_DIR/body.json"

# --- Headers (kept in a 0600 file so the key never appears in the process list)
umask 077
{
    printf 'Authorization: Bearer %s\n' "$KEY"
    printf 'Content-Type: application/json; charset=utf-8\n'
    printf 'Accept: %s\n' "$ACCEPT"
    printf 'User-Agent: %s\n' "$USER_AGENT"
    printf 'originator: %s\n' "$ORIGINATOR"
    printf 'session-id: %s\n' "$SESSION_ID"
    printf 'thread-id: %s\n' "$SESSION_ID"
    printf 'x-client-request-id: %s\n' "$(new_uuid)"
} > "$TMP_DIR/headers.txt"

# --- Send -------------------------------------------------------------------
echo "  Prompt: ${PROMPT:0:70}..."
echo "  Endpoint: POST $EP_URL  [style=$EP_STYLE, model=$MODEL]"

START_TS=$(date +%s)
CURL_EXIT=0
HTTP_CODE=$(curl -sS --max-time "$REQUEST_TIMEOUT" --no-progress-meter \
    --output "$TMP_DIR/body.out" --write-out '%{http_code}' \
    --request POST "$EP_URL" \
    --header "@$TMP_DIR/headers.txt" \
    --data-binary "@$TMP_DIR/body.json" 2> "$TMP_DIR/curl.err") || CURL_EXIT=$?
ELAPSED=$(( $(date +%s) - START_TS ))

parse_probe_response "$TMP_DIR/body.out" || true

# --- Report raw diagnostics -------------------------------------------------
echo "  HTTP $HTTP_CODE  |  ${ELAPSED}s  |  status=${RESP_STATUS:-?}"

if [ -s "$TMP_DIR/body.out" ]; then
    echo "  --- response (first 800 bytes) ---"
    head -c 800 "$TMP_DIR/body.out" | sed 's/^/    /'
    echo ""
    echo "  --- end response ---"
fi

FAIL_REASON=""
if [ "$CURL_EXIT" -ne 0 ]; then
    FAIL_REASON="curl exit $CURL_EXIT: $(head -c 300 "$TMP_DIR/curl.err" 2>/dev/null | tr '\n' ' ')"
elif [ "$HTTP_CODE" != "200" ]; then
    FAIL_REASON="HTTP $HTTP_CODE"
    [ -n "${RESP_ERROR:-}" ] && FAIL_REASON="$FAIL_REASON: $RESP_ERROR"
    if [ "$HTTP_CODE" = "404" ]; then
        FAIL_REASON="$FAIL_REASON (check BASE_URL path, API_STYLE and MODEL support)"
    fi
elif [ -n "${RESP_ERROR:-}" ]; then
    FAIL_REASON="API error: $RESP_ERROR"
elif [ -z "${RESP_TEXT//[[:space:]]/}" ]; then
    case "${RESP_STATUS:-}" in
        completed|incomplete) FAIL_REASON="" ;;   # 200 + terminal state: alive
        *) FAIL_REASON="empty answer (status=${RESP_STATUS:-unknown})" ;;
    esac
fi

if [ -n "$FAIL_REASON" ]; then
    echo "  FAILED ($FAIL_REASON)"
    exit 1
fi

if [ -n "${RESP_TEXT//[[:space:]]/}" ]; then
    ANSWER_PREVIEW=$(printf '%s' "$RESP_TEXT" | tr '\n' ' ')
    echo "  Answer: ${ANSWER_PREVIEW:0:160}"
fi
[ "${RESP_STATUS:-}" = "incomplete" ] && echo "  (note: response status incomplete - output token budget reached)"
echo "  SUCCESS (${ELAPSED}s)"
exit 0
