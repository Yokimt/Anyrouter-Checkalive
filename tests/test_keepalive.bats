#!/usr/bin/env bash
# Tests for the Codex keepalive scripts.
# Run with: bats tests/     (needs bash >= 4, jq, curl, python3)

setup() {
    cd "$BATS_TEST_DIRNAME/.." || return 1
    # shellcheck source=../scripts/lib.sh
    source scripts/lib.sh
    unset CODEX_TOKENS ANYROUTER_TOKENS
}

teardown() {
    if [ -n "${MOCK_PID:-}" ]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
        unset MOCK_PID
    fi
}

start_mock() {
    local ready="$BATS_TEST_TMPDIR/ready" _
    MOCK_PORT=$(( 20000 + RANDOM % 20000 ))
    rm -f "$ready"
    python3 tests/mock_server.py --port "$MOCK_PORT" --ready-file "$ready" \
        >"$BATS_TEST_TMPDIR/mock.log" 2>&1 &
    MOCK_PID=$!
    for _ in $(seq 1 100); do
        if [ -s "$ready" ]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# --- endpoint resolution ----------------------------------------------------

@test "resolve_endpoint appends /v1/responses to a bare base" {
    resolve_endpoint "https://example.test" "auto"
    [ "$EP_URL|$EP_STYLE" = "https://example.test/v1/responses|responses" ]
}

@test "resolve_endpoint keeps a /v1 base and appends the wire path" {
    resolve_endpoint "https://example.test/v1/" "auto"
    [ "$EP_URL|$EP_STYLE" = "https://example.test/v1/responses|responses" ]
}

@test "resolve_endpoint uses chat completions when asked" {
    resolve_endpoint "https://example.test/v1" "chat"
    [ "$EP_URL|$EP_STYLE" = "https://example.test/v1/chat/completions|chat" ]
}

@test "resolve_endpoint trusts a full /responses URL" {
    resolve_endpoint "https://example.test/api/responses" "auto"
    [ "$EP_URL|$EP_STYLE" = "https://example.test/api/responses|responses" ]
}

@test "resolve_endpoint rejects a conflicting style" {
    run bash -c 'source scripts/lib.sh; resolve_endpoint "https://x.test/v1/chat/completions" "responses"'
    [ "$status" -ne 0 ]
}

@test "resolve_endpoint rejects a non-http base" {
    run bash -c 'source scripts/lib.sh; resolve_endpoint "example.test/v1" "auto"'
    [ "$status" -ne 0 ]
}

# --- response parsing -------------------------------------------------------

@test "parse_probe_response reads Responses SSE deltas" {
    printf '%s\n\n' \
        'data: {"type":"response.output_text.delta","delta":"1"}' \
        'data: {"type":"response.output_text.delta","delta":"7"}' \
        'data: {"type":"response.completed","response":{"status":"completed","output":[]}}' \
        > "$BATS_TEST_TMPDIR/sse.txt"
    parse_probe_response "$BATS_TEST_TMPDIR/sse.txt"
    [ "$RESP_TEXT|$RESP_STATUS|$RESP_ERROR" = "17|completed|" ]
}

@test "parse_probe_response reads a plain Responses JSON body" {
    cat > "$BATS_TEST_TMPDIR/resp.json" <<'JSON'
{"id":"r1","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"17"}]}]}
JSON
    parse_probe_response "$BATS_TEST_TMPDIR/resp.json"
    [ "$RESP_TEXT|$RESP_STATUS" = "17|completed" ]
}

@test "parse_probe_response reads Chat Completions SSE" {
    printf '%s\n\n' \
        'data: {"choices":[{"delta":{"content":"4"},"finish_reason":null}]}' \
        'data: {"choices":[{"delta":{"content":"2"},"finish_reason":"stop"}]}' \
        'data: [DONE]' \
        > "$BATS_TEST_TMPDIR/chat.txt"
    parse_probe_response "$BATS_TEST_TMPDIR/chat.txt"
    [ "$RESP_TEXT|$RESP_STATUS" = "42|stop" ]
}

@test "parse_probe_response surfaces an API error object" {
    printf '%s' '{"error":{"message":"invalid api key"}}' > "$BATS_TEST_TMPDIR/err.json"
    parse_probe_response "$BATS_TEST_TMPDIR/err.json"
    [ "$RESP_TEXT|$RESP_ERROR" = "|invalid api key" ]
}

@test "parse_probe_response handles a gateway that labels JSON as SSE" {
    printf '%s\n\n' 'data: {"error":{"message":"quota exceeded"}}' > "$BATS_TEST_TMPDIR/mixed.txt"
    parse_probe_response "$BATS_TEST_TMPDIR/mixed.txt"
    [ "$RESP_ERROR" = "quota exceeded" ]
}

# --- configuration ----------------------------------------------------------

@test "read_env_value parses a quoted multi-line value" {
    printf 'CODEX_TOKENS="k1\nk2"\nOTHER=1\n' > "$BATS_TEST_TMPDIR/env"
    run read_env_value "$BATS_TEST_TMPDIR/env" CODEX_TOKENS
    [ "$output" = "k1
k2" ]
}

@test "load_keys splits a multi-line env value" {
    export CODEX_TOKENS=$'sk-aaa\nsk-bbb'
    run load_keys
    [ "${lines[0]}|${lines[1]}" = "sk-aaa|sk-bbb" ]
}

@test "load_keys falls back to the legacy ANYROUTER_TOKENS name" {
    export ANYROUTER_TOKENS='sk-legacy'
    run load_keys
    [ "$output" = "sk-legacy" ]
}

@test "load_keys fails when nothing is configured" {
    run bash -c 'source scripts/lib.sh; PROJECT_DIR=/nonexistent; load_keys'
    [ "$status" -ne 0 ]
}

# --- end to end (mock endpoint) --------------------------------------------

@test "keepalive.sh succeeds against a Codex mock and hides the key" {
    start_mock
    run bash scripts/keepalive.sh "sk-secret-value" "http://127.0.0.1:$MOCK_PORT/v1" "gpt-6-astra" responses
    [ "$status" -eq 0 ] && [[ "$output" == *"SUCCESS"* && "$output" == *"17"* ]] \
        && [[ "$output" != *"sk-secret-value"* ]]
}

@test "keepalive.sh fails on HTTP 401" {
    start_mock
    run bash scripts/keepalive.sh "sk-test" "http://127.0.0.1:$MOCK_PORT/reject" "gpt-6-astra" responses
    [ "$status" -ne 0 ] && [[ "$output" == *"FAILED"* ]]
}

@test "keepalive.sh works over Chat Completions" {
    start_mock
    run bash scripts/keepalive.sh "sk-test" "http://127.0.0.1:$MOCK_PORT/v1" "gpt-6-astra" chat
    [ "$status" -eq 0 ] && [[ "$output" == *"42"* ]]
}

@test "run-all.sh --once completes one round" {
    start_mock
    run env CODEX_TOKENS="sk-test" BASE_URL="http://127.0.0.1:$MOCK_PORT/v1" \
        MODEL="gpt-6-astra" bash scripts/run-all.sh --once
    [ "$status" -eq 0 ] && [[ "$output" == *"Loaded 1 key(s)"* && "$output" == *"Round 1 summary: 1 success"* ]]
}

@test "monitor-recovery.sh exits early when everything is healthy and fast" {
    start_mock
    run env CODEX_TOKENS="sk-test" BASE_URL="http://127.0.0.1:$MOCK_PORT/v1" \
        MODEL="gpt-6-astra" MAX_DURATION_SEC=120 POLL_INTERVAL=5 \
        timeout 40 bash scripts/monitor-recovery.sh
    [ "$status" -eq 0 ] && [[ "$output" == *"Early exit"* ]]
}
