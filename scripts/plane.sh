#!/usr/bin/env bash
# plane.sh — Plane REST API CLI（Scrum 秘书 plane-scribe 专用）
# 依赖: curl, jq
# 环境变量:
#   PLANE_API_KEY     必填，Plane → Profile Settings → Personal Access Tokens
#   PLANE_WORKSPACE   必填，workspace slug
#   PLANE_PROJECT_ID  大多数命令必填（projects 命令除外）
#   PLANE_BASE_URL    可选，默认 https://api.plane.so（自部署改此处）
#   PLANE_ENV_FILE    可选，指向一个 shell 片段，脚本会在 set -a 下 source 它，
#                     适合自部署用户把 PLANE_API_KEY / PLANE_WORKSPACE 集中放一处
if [ -n "${PLANE_ENV_FILE:-}" ] && [ -r "$PLANE_ENV_FILE" ]; then
  set +e; set -a; . "$PLANE_ENV_FILE"; set +a; set -e
fi
set -euo pipefail

# 项目级配置自动发现：从 $PWD 向上找 .zcode/.env（最多 6 层），source 后注入 PLANE_* 变量
# 优先级：全局 env > $PLANE_ENV_FILE > 项目 .zcode/.env > 默认值；只补未设置的变量，全局 env 优先（账号级 key 不被项目文件覆盖）
if [ -z "${PLANE_ENV_FILE:-}" ]; then
  _search_dir="${PWD:-.}"
  for _i in 1 2 3 4 5 6; do
    if [ -r "$_search_dir/.zcode/.env" ]; then
      while IFS= read -r _env_line; do
        if [[ "$_env_line" =~ ^[[:space:]]*(export[[:space:]]+)?(PLANE_[A-Za-z0-9_]*)=(.*)$ ]]; then
          _env_key="${BASH_REMATCH[2]}"
          _env_val="${BASH_REMATCH[3]}"
          # 去掉首尾单/双引号
          _env_val="${_env_val#\"}"; _env_val="${_env_val%\"}"
          _env_val="${_env_val#\'}"; _env_val="${_env_val%\'}"
          # 仅当未设置时导出（全局 env 优先）
          if [ -z "${!_env_key+x}" ]; then
            printf -v "$_env_key" '%s' "$_env_val"
            export "$_env_key"
          fi
        fi
      done < "$_search_dir/.zcode/.env"
      break
    fi
    [ "$_search_dir" = "/" ] && break
    _search_dir="$(dirname "$_search_dir")"
  done
  unset _search_dir _i _env_line _env_key _env_val
fi

BASE="${PLANE_BASE_URL:-https://api.plane.so}"
WS="${PLANE_WORKSPACE:?need PLANE_WORKSPACE}"
API="$BASE/api/v1/workspaces/$WS"
AUTH=(-H "X-API-Key: ${PLANE_API_KEY:?need PLANE_API_KEY}" -H "Content-Type: application/json")
PID="${PLANE_PROJECT_ID:-}"
CACHE="${TMPDIR:-/tmp}/plane-states-$WS${PID:+-$PID}.json"

usage() {
  cat <<'EOF'
用法: plane.sh <命令> [参数]
  projects                                  列出全部项目
  states                                    列出项目状态（name / group / uuid）
  issue-create --title T [--desc-file F | --desc S] [--state NAME] [--priority P] [--labels a,b]
  issue-list [--state NAME] [--cycle ID]    列卡（可按状态名或 cycle 过滤）
  issue-get <issue-id>                      查看单卡
  issue-move <issue-id> <状态名>            移状态（如 In-Progress / Done）
  issue-comment <issue-id> <文本>
  cycle-list                                列 Sprint
  cycle-add <cycle-id> <issue-id>           把卡排入 Sprint
  page-create --title T --file F            建 wiki 页（部分自部署版本不支持）
EOF
  exit 1
}

req_pid() { [[ -n "$PID" ]] || { echo "错误: 需要 PLANE_PROJECT_ID" >&2; exit 2; }; }

api() { # api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$API$path" "${AUTH[@]}" -d "$body"
  else
    curl -sS -X "$method" "$API$path" "${AUTH[@]}"
  fi
}

fetch_all() { # fetch_all PATH — 翻页拉全量 results
  local path="$1" out="[]" off=0 page
  while :; do
    page=$(api GET "$path?limit=100&offset=$off")
    out=$(jq -c --argjson a "$out" '(.results // []) as $r | $a + $r' <<<"$page")
    local n; n=$(jq '(.results // []) | length' <<<"$page")
    [[ "$n" -eq 100 ]] || break
    off=$((off + 100))
  done
  echo "$out"
}

states_map() { # name→{id,group} 映射，带本地缓存
  if [[ ! -s "$CACHE" ]]; then
    req_pid
    fetch_all "/projects/$PID/states/" | jq -c 'map({key: .name, value: {id: .id, group: .group}}) | from_entries' > "$CACHE"
  fi
  cat "$CACHE"
}

state_id() {
  local id
  id=$(states_map | jq -r --arg n "$1" '.[$n].id // empty')
  if [[ -z "$id" && -s "$CACHE" ]]; then # 缓存可能陈旧（如新建状态后）：失效重取一次
    rm -f "$CACHE"
    id=$(states_map | jq -r --arg n "$1" '.[$n].id // empty')
  fi
  [[ -n "$id" ]] || { echo "错误: 状态 \"$1\" 不存在。运行: plane.sh states" >&2; exit 3; }
  echo "$id"
}

issue_exists() { # 语义校验：issue-id 是否真实存在；避免无效 PATCH/POST 静默失败（避免把不存在的卡误置状态）
  local id="$1" code
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X GET "$API/projects/$PID/issues/$id/" "${AUTH[@]}")
  [[ "$code" == "200" ]]
}

valid_priority() { # 语义校验：priority 必须是 Plane 定义的 5 档之一
  case "$1" in urgent|high|medium|low|none) return 0;; *) return 1;; esac
}

html_wrap() { # 纯文本 → <pre> 保留换行
  jq -Rn --arg t "$1" '("<pre>" + $t + "</pre>")'
}

label_ids() { # 按名解析 label，不存在则创建
  local names="$1" existing want name ids="[]"
  existing=$(fetch_all "/projects/$PID/labels/")
  IFS=',' read -ra want <<<"$names"
  for name in "${want[@]}"; do
    name=$(echo "$name" | xargs)
    [[ -n "$name" ]] || continue
    local lid; lid=$(jq -r --arg n "$name" 'map(select(.name == $n))[0].id // empty' <<<"$existing")
    if [[ -z "$lid" ]]; then
      lid=$(api POST "/projects/$PID/labels/" "$(jq -n --arg n "$name" '{name:$n}')" | jq -r '.id')
    fi
    ids=$(jq -c --arg v "$lid" '. + [$v]' <<<"$ids")
  done
  echo "$ids"
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift

case "$cmd" in
  projects)
    api GET "/projects/" | jq '.results | map({id, name, identifier})'
    ;;
  states)
    states_map | jq .
    ;;
  issue-create)
    req_pid
    local_title="" desc="" st="" pr="none" labels=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) local_title="$2"; shift 2;;
        --desc) desc="$2"; shift 2;;
        --desc-file) desc="$(cat "$2")"; shift 2;;
        --state) st="$2"; shift 2;;
        --priority) pr="$2"; shift 2;;
        --labels) labels="$2"; shift 2;;
        *) echo "未知参数: $1" >&2; exit 1;;
      esac
    done
    [[ -n "$local_title" ]] || { echo "错误: --title 必填" >&2; exit 1; }
    valid_priority "$pr" || { echo "错误: --priority 必须是 urgent/high/medium/low/none 之一，当前: $pr" >&2; exit 1; }
    body=$(jq -n --arg n "$local_title" --argjson d "$(html_wrap "$desc")" --arg p "$pr" \
      '{name:$n, description_html:$d, priority:$p}')
    [[ -n "$st" ]] && body=$(jq -c --arg s "$(state_id "$st")" '. + {state:$s}' <<<"$body")
    [[ -n "$labels" ]] && body=$(jq -c --argjson l "$(label_ids "$labels")" '. + {labels:$l}' <<<"$body")
    api POST "/projects/$PID/issues/" "$body" | jq '{id, name, state, priority}'
    ;;
  issue-list)
    req_pid
    data=$(fetch_all "/projects/$PID/issues/")
    if [[ "${1:-}" == "--state" ]]; then
      sid=$(state_id "$2"); data=$(jq -c --arg s "$sid" 'map(select(.state == $s))' <<<"$data")
    fi
    if [[ "${1:-}" == "--cycle" ]]; then
      data=$(fetch_all "/projects/$PID/cycles/$2/cycle-issues/" \
        | jq -c 'map(.issue // .issue_id)')
    fi
    echo "$data" | jq 'map({id, name: (.name // .title), state, priority})'
    ;;
  issue-get)
    req_pid; api GET "/projects/$PID/issues/$1/" | jq '{id, name, state, priority, description_html}'
    ;;
  issue-move)
    req_pid
    [[ $# -eq 2 ]] || { echo "用法: issue-move <issue-id> <状态名>" >&2; exit 1; }
    issue_exists "$1" || { echo "错误: issue-id \"$1\" 不存在（issue-get 后查真实 ID）" >&2; exit 4; }
    sid=$(state_id "$2") # 先解析后 PATCH：解析失败必须中止，禁止空 state 的 PATCH（会误置回 Backlog）
    api PATCH "/projects/$PID/issues/$1/" "$(jq -n --arg s "$sid" '{state:$s}')" \
      | jq '{id, name, state}'
    ;;
  issue-comment)
    req_pid
    api POST "/projects/$PID/issues/$1/comments/" "$(jq -n --arg c "$2" '{comment_html:("<pre>"+$c+"</pre>")}')" \
      | jq '{id, comment_html}'
    ;;
  cycle-list)
    req_pid; api GET "/projects/$PID/cycles/" | jq '.results | map({id, name, start_date, end_date})'
    ;;
  cycle-add)
    req_pid
    api POST "/projects/$PID/cycles/$1/cycle-issues/" "$(jq -n --arg i "$2" '{issues:[$i]}')" \
      | jq '{id: .id, added: .issues}'
    ;;
  page-create)
    req_pid
    t="" f=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) t="$2"; shift 2;;
        --file) f="$2"; shift 2;;
        *) shift;;
      esac
    done
    api POST "/projects/$PID/pages/" "$(jq -n --arg t "$t" --arg d "$(cat "$f")" '{title:$t, description:$d}')" \
      | jq '{id, title}'
    ;;
  *)
    usage
    ;;
esac