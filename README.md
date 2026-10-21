# Codex Keepalive

对 **Codex** 接口做多 key 健康检查（保活）与恢复监控，通过 GitHub Actions 定时运行，让账号在调度队列中保持活跃状态。默认模型 **`gpt-6-astra`**。

改造自原 Anyrouter-Claude 版本，请求形态参考 `codex_keepalive_v20`：**不安装任何 CLI**，直接用 `curl` 调 Codex 兼容的 HTTP 接口。

## 与上一版（Claude）的区别

| 维度 | 上一版 | 现在 |
|---|---|---|
| 探活方式 | 装 Claude Code CLI，跑 `claude -p` | `curl` 直接 POST Codex HTTP 接口 |
| 凭据落盘 | 每次改写并删除 `~/.claude/settings.json` | 只放在 0600 临时请求头文件里，随进程删除 |
| 默认模型 | `opus[1m]` | `gpt-6-astra` |
| CI 依赖 | Node + Claude CLI（每次现装） | `jq` + `curl`（ubuntu-latest 自带） |
| 成功判定 | 退出码 + 非空输出 | HTTP 200 + 解析出的回答文本 |

## 工作原理

### 请求形态

对齐参考项目 `codex_keepalive_v20`：原生 HTTP，凭证只进请求头。

```http
POST https://anyrouter.top/v1/responses
Authorization: Bearer sk-xxx
Content-Type: application/json; charset=utf-8
Accept: text/event-stream
User-Agent: Codex Desktop (codex-keepalive/1.0)
originator: Codex Desktop
session-id: <uuid4>
thread-id: <uuid4>
x-client-request-id: <uuid4>
```

```jsonc
{
  "model": "gpt-6-astra",
  "stream": true,
  "store": false,
  "instructions": "回答下面的问题。直接给出结论……",
  "input": [{"type": "message", "role": "user",
             "content": [{"type": "input_text", "text": "<随机提问>"}]}],
  "max_output_tokens": 128,
  "prompt_cache_key": "<session-id>",
  "reasoning": {"effort": "low"},
  "text": {"verbosity": "low"}
}
```

`reasoning` / `text` 只在模型名以 `gpt-5` / `gpt-6` 开头时添加；`REASONING_EFFORT=`（空）可关闭。

**成功判定**（与参考项目一致）：

- HTTP 200 且能从 Responses / Chat Completions（JSON 或 SSE）里解析出回答文本 → 存活；
- `status=incomplete`（输出预算用尽）**也算存活**，只记一条提示；
- 网络错误、超时、非 200、响应体带 `error`、空回答 → 失败。

### 端点推导

`BASE_URL` 可以是裸主机、带 `/v1`，也可以直接是完整接口地址：

| `BASE_URL` | `API_STYLE` | 实际请求 |
|---|---|---|
| `https://anyrouter.top` | `auto` | `https://anyrouter.top/v1/responses` |
| `https://anyrouter.top/v1` | `auto` | `https://anyrouter.top/v1/responses` |
| `https://anyrouter.top/v1` | `chat` | `https://anyrouter.top/v1/chat/completions` |
| `https://x/api/responses` | `auto` | 原样使用（并锁定 responses 格式） |
| `https://x/v1/chat/completions` | `responses` | 报错（格式冲突） |

`auto` 只决定「路径怎么拼」，不会在请求失败后自动换协议：如果平台只支持 chat completions，请显式设 `API_STYLE=chat`。

### 保活 / 恢复监控

- **Keepalive**：每天 UTC 18:00（北京时间 02:00）起一个 ~8 小时窗口（6h 主段 + 2h 续段），内部每 ~50 分钟轮询全部 key，每段结束发一封汇总邮件。
- **Recovery Monitor**：手动起 6 小时容器，每 30 分钟一轮、每轮发邮件；全部 key 正常且最大响应 < 30 秒时发「快用」邮件并提前退出。
- 每轮 key 之间 30 秒 ± 10 秒抖动，避免瞬时并发。

## 快速开始

### 先说明一件事：Actions 不会弹窗让你填密钥

GitHub 的 secret 是**仓库级配置**，不是运行参数。`Run workflow` 面板里的输入框只能传 `base_url`、`model`、`api_style` 这类非敏感参数；密钥必须提前写进 Secrets，否则工作流跑起来第一步就会红，并给出「缺少 API 密钥」的注解。

### 1. Fork 仓库

### 2. 配置 Secrets（必做）

**Settings → Secrets and variables → Actions → New repository secret**：

| Secret | 说明 | 必需 |
|---|---|---|
| `CODEX_TOKENS` | Codex API key，每行一个 | ✅ |
| `QQ_EMAIL` | 接收报告的 QQ 邮箱 | ❌ 可选 |
| `QQ_SMTP_AUTH_CODE` | QQ 邮箱 SMTP 授权码（不是登录密码） | ❌ 可选 |

> 旧仓库不用改：`ANYROUTER_TOKENS` 仍然可用，工作流会按 `CODEX_TOKENS → ANYROUTER_TOKENS` 顺序回退。
>
> **邮件不配也能跑**：`QQ_EMAIL` / `QQ_SMTP_AUTH_CODE` 缺任意一个时，任务照常执行，只是不发邮件，日志里会出现 `(Skipping email: ...)`。想收邮件就把两个都配上，然后在 QQ 邮箱「设置 → 账号 → POP3/IMAP/SMTP」生成授权码。

配好后每次运行会在 Actions 的 **Summary** 页显示本次的端点、格式、模型、key 数量和邮件状态；`preflight.sh` 会在开跑前就把缺项报出来，不用等 6 小时结束才发现。

### 3. 启用 Actions

Actions 页面 → “I understand my workflows, go ahead and enable them”。

## 配置项

全部通过环境变量（工作流里已接好输入框）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CODEX_TOKENS` | — | key 列表，换行分隔（逗号分割也兼容） |
| `ANYROUTER_TOKENS` | — | 旧变量名，`CODEX_TOKENS` 为空时的回退 |
| `BASE_URL` / `CODEX_BASE_URL` | `https://anyrouter.top/v1` | 接口地址，可带完整路径 |
| `MODEL` / `CODEX_MODEL` | `gpt-6-astra` | 模型名 |
| `API_STYLE` | `auto` | `auto` / `responses` / `chat` |
| `REQUEST_TIMEOUT` | `90` | 单次请求超时（秒） |
| `MAX_OUTPUT_TOKENS` | `128` | 输出预算（含推理 token） |
| `REASONING_EFFORT` | `low` | 推理强度；设为空则不带 `reasoning`/`text` 字段 |
| `STREAM` | `1` | `1` 走 SSE，`0` 走普通 JSON |
| `CHAT_TOKEN_PARAM` | `auto` | chat 格式的输出上限字段名 |
| `CODEX_INSTRUCTION` | 内置中文指令 | 系统指令 |
| `SLEEP_BETWEEN_TOKENS` | `30` | key 间隔（秒） |
| `SLEEP_BETWEEN_ROUNDS` | `3000` | 保活轮间隔（秒） |
| `MAX_DURATION_SEC` | `21500` | 单次运行时长上限（≈5h58m） |
| `POLL_INTERVAL` | `1800` | 监控轮间隔（秒） |
| `FAST_THRESHOLD_SEC` | `30` | 提前退出阈值（最大响应秒数） |
| `QQ_EMAIL` / `QQ_SMTP_AUTH_CODE` | — | 邮件报告，留空则跳过 |

## 工作流

| 工作流 | 触发 | 用途 |
|---|---|---|
| **Codex Keepalive** (`keepalive.yml`) | 定时 + 手动 | 每日保活，每 ~50 分钟一轮 |
| **Codex Keepalive (Once)** (`keepalive-once.yml`) | 手动 | 单轮快速测活 |
| **Codex Recovery Monitor** (`monitor-recovery.yml`) | 手动 | 每 30 分钟监控 + 恢复即早退 |
| **Tests** (`test.yml`) | push / PR | `bash -n` + `shellcheck` + `bats` |

### 为什么 Actions 里看不到定时运行

这是最常见的疑问，属于正常现象：

- GitHub **只为已发生的触发生成运行记录**，不会提前显示「下一次执行时间」；刚配好时运行列表里只有手动/推送记录。
- 保活的 cron 是 `0 18 * * *`（UTC）→ 北京时间次日 02:00。所以配好后要等到**下一个 18:00 UTC** 才会出现第一条 `Scheduled` 运行。
- GitHub 的 cron 允许延迟，高峰时 10–60 分钟属正常，偶尔也会跳过当次。
- **fork 仓库**的定时工作流默认可能被禁用：到 Actions → Codex Keepalive 看有没有 **Enable workflow** 按钮。
- 公开仓库连续 60 天无提交后，schedule 会被自动停用（推送一次即可恢复）。

想立刻验证链路，直接点 **Run workflow** （等价于 `workflow_dispatch`），或临时把 cron 改成 `*/5 * * * *` 推上去、验证完再改回来。

### 8 小时窗口是怎么来的

GitHub 对**单个 job** 有 6 小时（360 分钟）硬上限 —— `MAX_DURATION_SEC=28800` 也会在第 6 小时被强制终止。所以 8 小时由两个 job 串起来：

| 段 | job | 时长预算 | 说明 |
|---|---|---|---|
| 1/2 | `keepalive` | ~5h58m（21500s） | 主段，`timeout-minutes: 360` |
| 2/2 | `keepalive-continue` | 2h（7200s） | `needs` 接在主段之后，`timeout-minutes: 150` |

- 两段之间会有几十秒到几分钟的空档（job 排队 + checkout），不是严格无缝。
- 每段结束各发一封汇总邮件（一天两封）。
- 主段即使失败，续段仍会执行（`always()`），避免一个坏 key 把窗口砍短。
- **退回 6 小时**：Settings → Variables 加 `KEEPALIVE_EXTEND = false`，续段就不跑了。
- 想更长就再串一个 job，但要按每天 480 分钟以上计算 Actions 消耗。

## 调整启动时间

**硬限制**：`on.schedule.cron` 只接受字面量 —— 不能用 `${{ vars.* }}`、secret 或 `Run workflow` 的输入框动态生成。启动时间必须写进 YAML，这是 GitHub 的规则。

### 方法 A：脚本换算并改文件（推荐）

```bash
# 改成北京时间 02:00 启动
bash scripts/set-cron.sh 02:00

# 只看换算结果，不改文件
bash scripts/set-cron.sh 07:30 --dry-run

git diff .github/workflows/keepalive.yml
git add -A && git commit -m "chore: keepalive start at 02:00 Beijing" && git push
```

脚本负责 北京时间 → UTC 的换算（-8 小时，跨零点自动回绕：`07:30` → `30 23 * * *`），并同步更新 `# keepalive-start:` 注释行。

### 方法 B：网页上直接改

仓库 → `.github/workflows/keepalive.yml` → 铅笔图标 → 只改这一行 → Commit changes 到 `main`：

```yaml
    # keepalive-start: UTC 18:00 = Beijing 02:00 ...
    - cron: "0 18 * * *"
```

### 换算表

| 北京时间 | UTC | cron |
|---|---|---|
| 00:00 | 前一天 16:00 | `0 16 * * *` |
| 02:00 | 前一天 18:00 | `0 18 * * *` |
| 08:00 | 00:00 | `0 0 * * *` |
| 12:00 | 04:00 | `0 4 * * *` |
| 20:00 | 12:00 | `0 12 * * *` |
| 23:30 | 15:30 | `30 15 * * *` |

一次保活默认约 8 小时（6h + 2h 两段）：02:00 启动意味着 02:00–10:00 持续在跑，起得越早越要算 Actions 分钟数。

### 不用改文件的部分

运行时长和节奏可以在 **Settings → Secrets and variables → Actions → Variables** 里建变量，工作流会读取（缺省时脚本自动回落）：

| Variable | 含义 | 默认 |
|---|---|---|
| `MAX_DURATION_SEC` | 单次运行时长上限 | 21500（≈5h58m） |
| `KEEPALIVE_EXTEND` | 设为 `false` 关闭第 2 段（退回 6h） | 开启 |
| `SLEEP_BETWEEN_ROUNDS` | 保活轮间隔秒数 | 3000（≈50 分钟） |
| `SLEEP_BETWEEN_TOKENS` | key 之间间隔秒数 | 30 |
| `POLL_INTERVAL` | 监控轮间隔秒数 | 1800 |

## 本地运行

需要 **bash ≥ 4**、`jq`、`curl`、`python3`（仅测试需要）。

```bash
# 单 key 测活（最直接的排错入口）
bash scripts/keepalive.sh "sk-your-key"
bash scripts/keepalive.sh "sk-your-key" "https://anyrouter.top/v1" "gpt-6-astra" "responses"

# 查看实际会请求的地址（不发送请求）
bash -c 'source scripts/lib.sh; resolve_endpoint "https://anyrouter.top/v1" auto; echo "$EP_STYLE $EP_URL"'

# 单轮批量（跳过 50 分钟等待）
export CODEX_TOKENS="sk-xxx111
sk-xxx222"
bash scripts/run-all.sh --once

# 恢复监控，自定义节奏
POLL_INTERVAL=600 MAX_DURATION_SEC=3600 bash scripts/monitor-recovery.sh

# 用 .env
cp .env.example .env
bash scripts/run-all.sh --once
```

## 测试

```bash
sudo apt-get install -y bats jq    # 或 brew install bats-core jq
bats tests/
```

`tests/mock_server.py` 会起一个本地假 Codex 端点（SSE / JSON / 401 三种情况），端到端验证探测与两个编排脚本。

## 文件结构

```
├── .github/workflows/
│   ├── keepalive.yml            # 定时 + 手动保活
│   ├── keepalive-once.yml       # 单轮测活
│   ├── monitor-recovery.yml     # 恢复监控
│   └── test.yml                 # 语法 / shellcheck / bats
├── scripts/
│   ├── lib.sh                   # 共享：端点推导、key 加载、SSE/JSON 解析、邮件
│   ├── preflight.sh             # 开跑前检查密钥/端点/邮件配置
│   ├── set-cron.sh              # 换算并修改定时启动时间
│   ├── keepalive.sh             # 单 key 探测（核心能力）
│   ├── run-all.sh               # 批量保活（50 分钟轮询）
│   ├── monitor-recovery.sh      # 恢复监控（30 分钟轮询 + 早退）
│   └── prompts.txt              # 60 条提问（30 工程 + 30 轻量）
├── tests/
│   ├── mock_server.py           # 本地假 Codex 端点
│   └── test_keepalive.bats      # 27 个用例
├── .env.example
├── .shellcheckrc
└── README.md
```

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| Actions 第一步就红：`缺少 API 密钥` | 没建 `CODEX_TOKENS`（或 `ANYROUTER_TOKENS`）secret | Settings → Secrets and variables → Actions 里新建；点开红色注解有完整提示 |
| 任务成功但收不到邮件 | 未配 `QQ_EMAIL` / `QQ_SMTP_AUTH_CODE`，或授权码用了登录密码 | 日志里会打印 `Skipping email`；补齐两个 secret 并重新生成授权码 |
| `HTTP 404` | 地址路径不对，或该平台不支持 `responses` | 改 `API_STYLE=chat`，或把 `BASE_URL` 换成完整接口地址 |
| `HTTP 401/403` | key 无效、不是该平台的 key | 检查 `CODEX_TOKENS` 与 `BASE_URL` 是否配套 |
| `empty answer (status=...)` | 输出预算太小 / 接口返回空 | 提高 `MAX_OUTPUT_TOKENS`（128 → 256/512） |
| `API error: ...` | 接口返回了错误体（限流、额度、模型不存在） | 按错误文案处理；模型名确认是 `gpt-6-astra` |
| `curl exit 28` | 请求超时 | 提高 `REQUEST_TIMEOUT`，或确认网络 |
| 邮件收不到 | SMTP 授权码错 / 用了登录密码 | 重新生成授权码；看日志里的 `Email FAILED` |
| 全部 key 同时失败 | 平台故障或 key 过期 | 先跑 `keepalive-once` 单轮确认 |

日志里每个 key 都会打印 `HTTP <code> | <秒> | status=<…>`，以及响应体前 800 字节，定位问题不需要复现。

## 注意事项

- **密钥安全**：key 只出现在 0600 权限的临时请求头文件里，进程退出即删；日志只打印前 5 位。不要把 key 写进 workflow 文件。
- **成本**：每次探测是一次真实模型调用。`gpt-6-astra` 的单价请按平台计费核对；可用 `MAX_OUTPUT_TOKENS` 压低单次成本。
- **Actions 分钟数**：每次约 8 小时 ≈ 480 分钟，按天跑约 14400 分钟/月。公开仓库免费；私有仓库会远超免费额度（Free 2000 / Pro 3000）。把仓库变量 `KEEPALIVE_EXTEND` 设为 `false` 可退回 6 小时（≈10800 分钟/月）。
- **定时任务**：公开仓库连续 60 天无提交后 schedule 会被自动停用；fork 仓库默认不启用定时任务，需手动开启。
- **合规**：本工具通过定时请求维持账号活跃度，属于对目标平台调度策略的自动化干预。请自行确认符合 Anyrouter/平台的服务条款与 GitHub Actions 的使用条款，风险自负。
- **平台差异**：`gpt-6-astra` 是非标准模型名，是否可用完全取决于你配置的 `BASE_URL`；换平台时先跑一次 `keepalive-once`。
