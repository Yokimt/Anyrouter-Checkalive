#!/usr/bin/env bash
# lib.sh - Shared helpers for the Codex keepalive scripts.
# Sourced by keepalive.sh / run-all.sh / monitor-recovery.sh and the tests.
# Deliberately does NOT touch shell options: the caller owns set -euo pipefail.
#
# EP_STYLE / EP_URL are outputs of resolve_endpoint and consumed by the
# scripts that source this file, which ShellCheck cannot see here.
# shellcheck disable=SC2034

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$LIB_DIR")}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

# A session id shaped like the Codex client's thread id. No external deps.
new_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z'
    else
        printf '%04x%04x-%04x-4%04x-%04x-%04x%04x%04x\n' \
            "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM"
    fi
}

# ---------------------------------------------------------------------------
# Endpoint
# ---------------------------------------------------------------------------

# resolve_endpoint <base_url> <auto|responses|chat>
# Mirrors the reference client: a bare base URL gets /v1 + the wire path
# appended; a URL already ending in /responses or /chat/completions is used
# verbatim and pins the style.
# Sets EP_STYLE and EP_URL.
resolve_endpoint() {
    local base="${1:-}" style="${2:-auto}" scheme rest host path detected=""

    [ -n "$base" ] || die "BASE_URL is empty: set BASE_URL (or CODEX_BASE_URL) and retry"

    case "$base" in
        http://*|https://*) ;;
        *) die "BASE_URL must start with http:// or https:// (got: $base)" ;;
    esac
    case "$base" in
        *\?*|*'#'*) die "BASE_URL must not contain a query string or fragment (got: $base)" ;;
    esac

    scheme="${base%%://*}"
    rest="${base#*://}"
    case "$rest" in
        *@*) die "BASE_URL must not contain credentials; put the key in the token list" ;;
    esac

    base="${base%/}"
    rest="${base#*://}"
    host="${rest%%/*}"
    if [ "$rest" = "$host" ]; then
        path=""
    else
        path="/${rest#*/}"
    fi
    [ -n "$host" ] || die "BASE_URL has no host (got: $base)"

    case "$path" in
        */chat/completions) detected="chat" ;;
        */responses) detected="responses" ;;
    esac

    if [ -n "$detected" ]; then
        if [ "$style" != "auto" ] && [ "$style" != "$detected" ]; then
            die "BASE_URL already ends with /$detected but API_STYLE=$style"
        fi
        EP_STYLE="$detected"
        EP_URL="$scheme://$host$path"
        return 0
    fi

    case "$style" in
        responses|chat) ;;
        auto) style="responses" ;;
        *) die "API_STYLE must be auto, responses or chat (got: $style)" ;;
    esac

    [ -n "$path" ] || path="/v1"
    if [ "$style" = "chat" ]; then
        path="$path/chat/completions"
    else
        path="$path/responses"
    fi
    EP_STYLE="$style"
    EP_URL="$scheme://$host$path"
}

# ---------------------------------------------------------------------------
# Response parsing
# ---------------------------------------------------------------------------

# Extract the model's text from a Responses / Chat Completions payload.
JQ_TEXT='
def ctext:
  if type == "string" then .
  elif type == "array" then
    ([.[] | if type == "string" then . else (.text? // .refusal? // "") end] | join(""))
  else "" end;
if ((.output_text? // "") | length) > 0 then .output_text
elif ((.output? // []) | length) > 0 then
  ([.output[]? | (.content? // empty) | ctext] | join("\n"))
elif ((.choices? // []) | length) > 0 then
  ([.choices[]? | (.message? // {}) | (.content? // empty) | ctext] | join("\n"))
else "" end'

JQ_STATUS='
if (.status? // null) != null then (.status | tostring)
elif ((.choices? // []) | length) > 0 then (.choices[0].finish_reason? // "" | tostring)
else "" end'

JQ_ERROR='
if (.error? // null) == null then ""
else (if (.error | type) == "object" then (.error.message? // (.error | tostring))
      else (.error | tostring) end) end'

_parse_json_body() {
    local file="$1"
    RESP_TEXT=$(jq -r "$JQ_TEXT" "$file" 2>/dev/null || true)
    RESP_STATUS=$(jq -r "$JQ_STATUS" "$file" 2>/dev/null || true)
    RESP_ERROR=$(jq -r "$JQ_ERROR" "$file" 2>/dev/null || true)
}

_parse_sse() {
    local file="$1" stream last first

    stream=$(sed -n 's/^[[:space:]]*data:[[:space:]]*//p' "$file" 2>/dev/null || true)

    # Incremental text: Responses deltas, then Chat Completions deltas.
    RESP_TEXT=$(printf '%s\n' "$stream" | jq -R -j '
        (fromjson?) as $e | select(($e | type) == "object")
        | if ($e.type? // "") == "response.output_text.delta" then ($e.delta? // "")
          elif ($e.choices? // null) != null
            then ([$e.choices[]? | (.delta?.content? // empty)] | join(""))
          else "" end' 2>/dev/null | tr -d '\r' || true)

    # Some gateways stream only the terminal event: take the answer from it.
    if [ -z "$RESP_TEXT" ]; then
        last=$(printf '%s\n' "$stream" | jq -R -c '
            (fromjson?) as $e | select(($e | type) == "object")
            | select((($e.type? // "") == "response.completed")
                     or (($e.type? // "") == "response.incomplete"))
            | $e.response' 2>/dev/null | tail -n 1 || true)
        if [ -n "$last" ] && [ "$last" != "null" ]; then
            RESP_TEXT=$(printf '%s' "$last" | jq -r "$JQ_TEXT" 2>/dev/null || true)
        fi
    fi

    RESP_STATUS=$(printf '%s\n' "$stream" | jq -R -r '
        (fromjson?) as $e | select(($e | type) == "object")
        | if (($e.type? // "") == "response.completed")
             or (($e.type? // "") == "response.incomplete")
             or (($e.type? // "") == "response.failed")
          then (($e.response? // {}) | .status? // ($e.type? | ltrimstr("response.")))
          elif (($e.choices? // []) | length) > 0 then ($e.choices[0].finish_reason? // empty)
          else empty end' 2>/dev/null | tail -n 1 || true)

    RESP_ERROR=$(printf '%s\n' "$stream" | jq -R -r '
        (fromjson?) as $e | select(($e | type) == "object")
        | if (($e.type? // "") == "error") or (($e.error? // null) != null)
          then (if (($e.error? // null) | type) == "object"
                then ($e.error.message? // ($e.error | tostring))
                else (($e.error? // $e.message? // "") | tostring) end)
          else "" end' 2>/dev/null | tail -n 1 || true)

    # Gateways sometimes label a plain JSON error body as event-stream.
    if [ -z "${RESP_TEXT}${RESP_STATUS}${RESP_ERROR}" ]; then
        first=$(head -c 1 "$file" 2>/dev/null | tr -d '[:space:]' || true)
        if [ "$first" = "{" ]; then
            _parse_json_body "$file"
        fi
    fi
}

# parse_probe_response <file> -> RESP_TEXT / RESP_STATUS / RESP_ERROR
# Handles both a JSON body and an SSE body.
parse_probe_response() {
    local file="$1"
    RESP_TEXT=""
    RESP_STATUS=""
    RESP_ERROR=""

    if [ ! -s "$file" ]; then
        RESP_ERROR="empty response body"
        return 1
    fi

    if grep -q '^[[:space:]]*data:' "$file" 2>/dev/null; then
        _parse_sse "$file"
    else
        _parse_json_body "$file"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Prompt pool
# ---------------------------------------------------------------------------

# pick_prompt [file] -> one random non-empty, non-comment line
pick_prompt() {
    local file="${1:-$LIB_DIR/prompts.txt}" prompts=() line
    if [ -f "$file" ]; then
        while IFS= read -r line; do
            line="${line%$'\r'}"
            [ -z "$line" ] && continue
            case "$line" in \#*) continue ;; esac
            prompts+=("$line")
        done < "$file"
        if [ "${#prompts[@]}" -gt 0 ]; then
            printf '%s\n' "${prompts[$((RANDOM % ${#prompts[@]}))]}"
            return 0
        fi
    fi
    printf '%s\n' "What is 17 * 23? Answer with the number only."
}

# ---------------------------------------------------------------------------
# API keys
# ---------------------------------------------------------------------------

# read_env_value <file> <KEY>
# Reads KEY=VALUE from a .env file, including a double-quoted value that
# spans several lines (which is how the token lists are documented).
read_env_value() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    awk -v key="$key" '
        BEGIN { kl = length(key) }
        substr($0, 1, kl + 1) == key "=" {
            v = substr($0, kl + 2)
            if (substr(v, 1, 1) == "\"") {
                v = substr(v, 2)
                if (v ~ /"$/) { sub(/"$/, "", v); print v; exit }
                print v
                while ((getline line) > 0) {
                    if (line ~ /"$/) { sub(/"$/, "", line); print line; exit }
                    print line
                }
                exit
            }
            print v
            exit
        }' "$file" 2>/dev/null | tr -d '\r' || true
}

# load_keys -> newline separated keys
# Order: CODEX_TOKENS env, ANYROUTER_TOKENS env (legacy), .env.
load_keys() {
    local data=""

    if [ -n "${CODEX_TOKENS:-}" ]; then
        data="$CODEX_TOKENS"
    elif [ -n "${ANYROUTER_TOKENS:-}" ]; then
        data="$ANYROUTER_TOKENS"
    else
        data=$(read_env_value "$PROJECT_DIR/.env" CODEX_TOKENS)
        if [ -z "$data" ]; then
            data=$(read_env_value "$PROJECT_DIR/.env" ANYROUTER_TOKENS)
        fi
    fi

    [ -n "${data//[[:space:]]/}" ] || return 1

    printf '%s\n' "$data" \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | sed '/^$/d'
}

# ---------------------------------------------------------------------------
# Email (QQ SMTP through curl)
# ---------------------------------------------------------------------------

# send_email <subject> <body>; reads QQ_EMAIL / QQ_SMTP_AUTH_CODE.
send_email() {
    local subject="$1" body="$2" mail_file curl_exit=0

    if [ -z "${QQ_EMAIL:-}" ] || [ -z "${QQ_SMTP_AUTH_CODE:-}" ]; then
        echo "  (Skipping email: QQ_EMAIL or QQ_SMTP_AUTH_CODE not configured)"
        return 0
    fi
    if ! curl --version 2>/dev/null | grep -qi "smtp"; then
        echo "  Email failed: curl was not compiled with SMTP support"
        return 1
    fi

    mail_file=$(mktemp)
    cat > "$mail_file" <<EOF
From: $QQ_EMAIL
To: $QQ_EMAIL
Subject: $subject
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: 8bit

$body
EOF

    echo "  Sending email via QQ SMTP to $QQ_EMAIL ..."
    curl -sS --max-time 60 --ssl-reqd --fail-with-body \
        --url "smtps://smtp.qq.com:465" \
        --user "$QQ_EMAIL:$QQ_SMTP_AUTH_CODE" \
        --login-options "AUTH=LOGIN" \
        --mail-from "$QQ_EMAIL" \
        --mail-rcpt "$QQ_EMAIL" \
        --upload-file "$mail_file" \
        || curl_exit=$?
    rm -f "$mail_file"

    if [ "$curl_exit" -eq 0 ]; then
        echo "  Email sent to $QQ_EMAIL"
        return 0
    fi
    echo "  Email FAILED (curl exit: $curl_exit)"
    echo "  Common causes:"
    echo "    - QQ_SMTP_AUTH_CODE is wrong (it is NOT your QQ password)"
    echo "    - Generate it at: QQ Mail -> Settings -> Account -> POP3/IMAP/SMTP"
    echo "    - Network/firewall blocking smtps://smtp.qq.com:465"
    return 1
}

# Beijing-time timestamp for reports.
beijing_ts() { TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S CST'; }
