#!/usr/bin/env bash
# preflight.sh - Validate the run configuration and fail fast with an
# actionable message *before* a 6-hour job starts.
#
# GitHub Actions never prompts for secrets: they are repository settings, not
# workflow inputs. This step turns a missing secret into one clear annotation
# instead of a bare "ERROR: No API keys found" buried in the log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

IN_ACTIONS=false
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    IN_ACTIONS=true
fi

fail() {
    local title="$1" message="$2"
    if [ "$IN_ACTIONS" = true ]; then
        printf '::error title=%s::%s\n' "$title" "$message"
    else
        printf 'ERROR: %s\n' "$message" >&2
    fi
    exit 1
}

warn() {
    local title="$1" message="$2"
    if [ "$IN_ACTIONS" = true ]; then
        printf '::warning title=%s::%s\n' "$title" "$message"
    else
        printf 'WARNING: %s\n' "$message" >&2
    fi
}

BASE_URL="${CODEX_BASE_URL:-${BASE_URL:-https://anyrouter.top/v1}}"
MODEL="${CODEX_MODEL:-${MODEL:-gpt-6-astra}}"
API_STYLE="${CODEX_API_STYLE:-${API_STYLE:-auto}}"

if ! KEYS_DATA="$(load_keys)"; then
    fail "缺少 API 密钥" \
        "没有找到 CODEX_TOKENS。到仓库 Settings → Secrets and variables → Actions → New repository secret，名称填 CODEX_TOKENS，值每行一个 key（旧的 ANYROUTER_TOKENS 也兼容）。密钥属于仓库配置，不会也不能通过 Run workflow 的输入框填写。"
fi

KEY_COUNT=$(printf '%s\n' "$KEYS_DATA" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')
if [ "${KEY_COUNT:-0}" -lt 1 ]; then
    fail "缺少 API 密钥" "CODEX_TOKENS 已创建但内容为空，请检查 secret 的值。"
fi

resolve_endpoint "$BASE_URL" "$API_STYLE"

EMAIL_STATE="未启用"
if [ -n "${QQ_EMAIL:-}" ] && [ -n "${QQ_SMTP_AUTH_CODE:-}" ]; then
    EMAIL_STATE="已启用"
else
    warn "邮件通知未启用" \
        "未配置 QQ_EMAIL / QQ_SMTP_AUTH_CODE：任务照常运行，但报告只写进 Actions 日志。需要邮件就在 Secrets 里补这两个值。"
fi

echo "配置检查通过：${KEY_COUNT} 个 key，${EP_STYLE} → ${EP_URL}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Codex Keepalive 本次运行配置"
        echo ""
        echo "| 项 | 值 |"
        echo "| --- | --- |"
        echo "| 端点 | \`${EP_URL}\` |"
        echo "| 请求格式 | \`${EP_STYLE}\` |"
        echo "| 模型 | \`${MODEL}\` |"
        echo "| key 数量 | ${KEY_COUNT} |"
        echo "| 邮件通知 | ${EMAIL_STATE} |"
    } >> "$GITHUB_STEP_SUMMARY"
fi
