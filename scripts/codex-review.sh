#!/usr/bin/env bash
# codex-review.sh — 用 Codex CLI 执行两段评审（spec=规约合规 / quality=代码质量）
# 评审规约（rubric）自动提取自 plugin/agents/{spec-reviewer,code-quality-reviewer}.md 正文，
# 与子智能体回退路径共用同一份规约，单一事实来源。
# 依赖: codex CLI（0.142+，已 codex login 或 OPENAI_API_KEY）、git
# 用法:
#   codex-review.sh spec    --repo <项目路径> --card <卡文件.md> [--base main] [--head HEAD]
#   codex-review.sh quality --repo <项目路径> --card <卡文件.md> [--base main] [--head HEAD]
# 环境变量: CODEX_BIN（默认 codex）、CODEX_REVIEW_MODEL（可选，透传 --model）
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"

usage() {
  echo "用法: codex-review.sh <spec|quality> --repo <项目路径> --card <卡文件.md> [--base main] [--head HEAD]" >&2
    exit 1
  }

MODE="${1:-}"; [[ $# -ge 1 ]] && shift
[[ "$MODE" == "spec" || "$MODE" == "quality" ]] || usage

REPO="" CARD="" BASE="" HEAD="HEAD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --card) CARD="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --head) HEAD="$2"; shift 2;;
    *) echo "未知参数: $1" >&2; usage;;
  esac
done
[[ -d "$REPO" ]] || { echo "错误: --repo 不是存在的目录" >&2; exit 1; }
[[ -f "$CARD" ]] || { echo "错误: --card 不是存在的文件" >&2; exit 1; }

# 找 rubric 文件 — 兼容 plugin 结构（新）和项目内结构（旧）两种部署
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 新结构：.../scrum-team-.../scripts/codex-review.sh → ../agents/spec-reviewer.md
# 旧结构：.../scrum-team/scripts/codex-review.sh（项目内） → ../../.zcode/agents/spec-reviewer.md
# 通用：从 PROJECT_DIST 插件根下的 agents/ 目录找
PLUGIN_ROOT="${SCRUM_PLUGIN_ROOT:-}"
if [[ -z "$PLUGIN_ROOT" ]]; then
  # 默认往上级目录找（scripts/ 的兄弟是 plugin 根）
  PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
fi
RUBRIC_NAME="spec-reviewer.md"
[[ "$MODE" == "quality" ]] && RUBRIC_NAME="code-quality-reviewer.md"

# 候选路径：plugin/agents/ + 项目内 .zcode/agents/
RUBRIC_FILE=""
for cand in \
  "$PLUGIN_ROOT/agents/$RUBRIC_NAME" \
  "$(dirname "$PLUGIN_ROOT")/.zcode/agents/$RUBRIC_NAME"; do
  if [[ -f "$cand" ]]; then RUBRIC_FILE="$cand"; break; fi
done
# 兜底：脚本所在目录的固定布局
if [[ -z "$RUBRIC_FILE" && -f "$SCRIPT_DIR/../agents/$RUBRIC_NAME" ]]; then
  RUBRIC_FILE="$SCRIPT_DIR/../agents/$RUBRIC_NAME"
fi
[[ -n "$RUBRIC_FILE" ]] || { echo "错误: 找不到评审规约 ${RUBRIC_NAME}（设 SCRUM_PLUGIN_ROOT 或放在 plugin/agents/ 或项目 .zcode/agents/ 下）" >&2; exit 1; }

rubric() { # 去掉 YAML frontmatter，取正文
  awk 'BEGIN{c=0} /^---[[:space:]]*$/{c++; next} c>=2{print}' "$1"
}

# 默认 base：依次尝试 main / master，都没有则要求显式指定
if [[ -z "$BASE" ]]; then
  for b in main master; do
    if git -C "$REPO" rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1; then BASE="$b"; break; fi
  done
fi
[[ -n "$BASE" ]] || { echo "错误: 无法推断 --base（仓库无 main/master），请显式指定评审基准分支" >&2; exit 1; }

DIFF="$(git -C "$REPO" diff "${BASE}...${HEAD}")"
[[ -n "$(echo "$DIFF" | tr -d '[:space:]')" ]] || { echo "错误: diff 为空（${BASE}...${HEAD}），无内容可评审" >&2; exit 4; }

TMP="$(mktemp -t codex-review-XXXXXXXX)"
PROMPT_FILE="${TMP}.prompt"
OUT_FILE="${TMP}.verdict.md"

{
  echo "# 评审规约（必须完整遵守，含输出协议）"
  echo
  rubric "$RUBRIC_FILE"
  echo
  echo "# 待评审材料"
  echo
  echo "## 用户故事卡（全文）"
  echo
  cat "$CARD"
  echo
  echo "## 代码变更（git diff ${BASE}...${HEAD}）"
  echo
  echo '```diff'
  git -C "$REPO" diff "${BASE}...${HEAD}"
  echo '```'
  echo
  echo "# 执行要求"
  echo "- 你处于只读评审模式：只读代码、只给结论，不创建、不修改、不删除任何文件。"
  echo "- diff 之外的相关实现可按需在仓库中阅读以核对上下文。"
  echo "- 最终回复必须严格按评审规约中的输出协议给结论行（✅/❌ 或 APPROVED/FIX_REQUIRED），并附逐项清单与 file:line 证据。"
} > "$PROMPT_FILE"

ARGS=(exec --sandbox read-only --skip-git-repo-check -C "$REPO" --output-last-message "$OUT_FILE")
[[ -n "${CODEX_REVIEW_MODEL:-}" ]] && ARGS+=(--model "$CODEX_REVIEW_MODEL")

# 预检：Codex CLI 在 PATH、版本足、API key 提示
if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  echo "错误: Codex CLI 未找到（PATH 里没有 ${CODEX_BIN}）。安装: https://github.com/openai/codex" >&2
  echo "提示: PM 应改用 general-purpose 子智能体内联 rubric 派发评审任务，绕过 Codex。" >&2
  exit 4
fi
CODEX_VERSION="$("$CODEX_BIN" --version 2>/dev/null || echo unknown)"
echo ">> Codex 版本: ${CODEX_VERSION}"
CODEX_MINOR="$(echo "$CODEX_VERSION" | sed -nE 's/^0\.([0-9]+).*/\1/p')"
if [[ -n "$CODEX_MINOR" && "$CODEX_MINOR" =~ ^[0-9]+$ ]] && (( CODEX_MINOR < 142 )); then
  echo "warning: Codex 版本 < 0.142（推荐升级），旧版可能不识别 exec 子命令的新参数。" >&2
fi
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "info: OPENAI_API_KEY 未设；依赖 'codex login' 存储凭据。反复 401 时运行 'codex login' 重登。" >&2
fi

LOG_FILE="${TMP}.log"
echo ">> Codex 评审启动（模式: ${MODE}，基准: ${BASE}...${HEAD}，rubric: ${RUBRIC_FILE}）"

# 限次重试 + 智能分诊：默认 10s/30s/90s；命中 429 切长退避 60s/180s/540s；命中 401/403 立即放弃
# 最终失败交由 PM 走既定回退路径（内联派发 subagent）
attempt=1; max_attempts=3; delay=10
while (( attempt <= max_attempts )); do
  if "${CODEX_BIN}" "${ARGS[@]}" "$(cat "$PROMPT_FILE")" >"$LOG_FILE" 2>&1 \
     && [[ -s "$OUT_FILE" ]] \
     && grep -qE '^(✅|❌|APPROVED|FIX_REQUIRED|SPEC_COMPLIANT|SPEC_ISSUES)' "$OUT_FILE"; then
    break
  fi
  # 凭据问题 → 立即放弃（重试无意义）
  if grep -qE '401|403|unauthorized|forbidden|invalid.*api[_-]?key|authentication' "$LOG_FILE" 2>/dev/null; then
    echo "错误: Codex 报凭据问题（401/403）。请运行 'codex login' 或检查 OPENAI_API_KEY。日志: ${LOG_FILE}" >&2
    echo "提示: PM 应改用 general-purpose 子智能体内联 rubric 派发评审任务，绕过 Codex。" >&2
    exit 8
  fi
  # 限流 → 重置为长退避基准
  if grep -qE '429|rate[ _-]?limit|quota[ _-]?exceeded|too many requests' "$LOG_FILE" 2>/dev/null; then
    echo "warning: Codex 报限流（429），改用长退避..." >&2
    delay=60
  fi
  if (( attempt < max_attempts )); then
    echo "warning: Codex 评审 attempt ${attempt}/${max_attempts} 未产出有效结论，${delay}s 后重试..." >&2
    sleep "$delay"
    delay=$((delay * 3))
  fi
  attempt=$((attempt + 1))
done

if (( attempt > max_attempts )); then
  echo "错误: Codex 评审 ${max_attempts} 次均失败。请检查：① 'codex login status' ② OPENAI_API_KEY 有效性 ③ OpenAI 服务状态 ④ 网络（公司网络/VPN 可能拦截 OpenAI API）。日志: ${LOG_FILE}" >&2
  echo "提示: PM 应改用 general-purpose 子智能体内联 rubric 派发评审任务，绕过 Codex。" >&2
  exit 5
fi

echo "== 评审结论（${OUT_FILE}）=="
cat "$OUT_FILE"