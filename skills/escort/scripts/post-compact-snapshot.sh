#!/usr/bin/env bash
# post-compact-snapshot.sh —— 上下文被压缩之后,把盘上现状塞回上下文:git log 10 条、分支 + status、
#   进度文件(progress.md)最新一条、任务树折叠版。挂 SessionStart matcher compact,stdin 是那次事件的 JSON。
# 长跑会话(context-gate.js --is-long 判)多一句「对照 task_plan 未完格接着干」。
# 不出声的情形:cwd 不在 git 仓、子 agent、坏输入。首行「[压缩后快照]」、末行「【快照完】」,末行没出来 = 被截断了。
# 任何错都 exit 0。
set -u
command -v timeout >/dev/null 2>&1 || timeout() { shift; "$@"; }   # macOS 没有 timeout:退回不限时
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(cat)"
IFS=$'\x1f' read -r CWD SID AGENT TP < <(printf '%s' "$PAYLOAD" | node -e '
let s = ""; process.stdin.on("data", (c) => s += c).on("end", () => {
  try { const d = JSON.parse(s); console.log(["cwd", "session_id", "agent_id", "transcript_path"].map((k) => String(d[k] || "").replace(/[\x1f\n]/g, " ")).join("\x1f")); } catch (_) {}
});' 2>/dev/null) || exit 0
[ -n "${CWD:-}" ] && [ -z "${AGENT:-}" ] || exit 0
case "${TP:-}" in */subagents/agent-*.jsonl) exit 0 ;; esac
ROOT="$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$ROOT" || exit 0

cap() { awk -v m="$1" 'NR<=m{print} END{if(NR>m) printf "…(另 %d 行没贴)\n", NR-m}'; }

if [ -n "${SID:-}" ] && timeout 2 node "$SELF_DIR/context-gate.js" --is-long "$SID" </dev/null 2>/dev/null; then
  HOW="长跑会话:对照 task_plan 未完格接着干,不用问从哪起;要拍板用 AskUserQuestion。"
else
  HOW="按压缩摘要接着手上的活。"
fi
echo "[压缩后快照] $(date '+%H:%M:%S'),上下文刚被压缩;下面是盘上现状。${HOW}这是快照,改文件前仍要复核要改的那几个;末行没有「【快照完】」= 被截断,缺的自己补跑。"

echo "== git log --oneline -10 =="
timeout 2 git log --oneline -10 2>&1 | cap 10
echo "== 分支 + git status --short =="
echo "分支:$(timeout 1 git branch --show-current 2>/dev/null)"
timeout 2 git -c core.quotePath=false status --short 2>&1 | cap 30

P="$ROOT/progress.md"; [ -f "$P" ] || P="$ROOT/planning/progress.md"
if [ -f "$P" ]; then
  # 各仓排序不一:比第一个和最后一个带日期的 ## 标题,后面的更新 = 最新在末尾,否则取顶部那条
  echo "== 进度最新一条($P)=="
  awk '/^## /{n++; h[n]=NR; if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) { d=substr($0, RSTART, 10); if (!f) {f=n; fd=d} l=n; ld=d } } {line[NR]=$0}
    END{ if (!n) exit; pick = (l && l != f && ld > fd) ? l : 1; end = (pick < n) ? h[pick+1]-1 : NR; for (i=h[pick]; i<=end; i++) print line[i] }' "$P" | cap 40
fi

if [ -f "$SELF_DIR/task-tree.sh" ] && { [ -f "$ROOT/task_plan.md" ] || [ -f "$ROOT/planning/task_plan.md" ]; }; then
  echo "== 任务树(折叠版)=="
  CLAUDE_PROJECT_DIR="$ROOT" timeout 2 bash "$SELF_DIR/task-tree.sh" 2>&1 | cap 30
fi
echo "【快照完】"
exit 0
