#!/usr/bin/env bash
# test-context-gate.sh —— context-gate.js 和 post-compact-snapshot.sh 的用例,带阴性对照。
#   跑法:bash test-context-gate.sh;要 node、git、bash。
#   全部改道到一个临时目录(数据文件、假 transcript、假仓都在里头),跑完删掉,不碰 ~/.claude 下任何东西。
#   末行 `PASS n/n`;有没过的打 `FAIL 过的数/总数: 组名…`,exit 1。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/context-gate.js"
SNAP="$HERE/post-compact-snapshot.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/escort-gate-test.XXXXXX")" || { echo "FAIL 0/0: 建不了临时目录"; exit 1; }
trap 'rm -rf "$T"' EXIT
for v in $(env | sed -n 's/^\(ESCORT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done   # 别让本机设的环境变量带歪用例
unset CLAUDE_CODE_SESSION_ID
export ESCORT_DATA_DIR="$T/data" ESCORT_PROJECTS_DIR="$T/projects"
LOGF="$T/data/gate.log"; SEENF="$T/data/seen.txt"; DONEF="$T/data/done.txt"; LONGF="$T/data/long.txt"
mkdir -p "$T/projects/p1"

total=0; passed=0; failed=""; G=""; G_BAD=0
need() { total=$((total+1)); if "$@"; then passed=$((passed+1)); else G_BAD=1; echo "  ✗ [$G] $*"; fi; }
group() { G="$1"; G_BAD=0; "$1"; if [ $G_BAD = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; failed="$failed $1"; fi; }

# 假 transcript:use 文件 响应号 占用 [模型]
use() { printf '{"type":"assistant","message":{"id":"m%s","model":"%s","usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}\n' "$2" "${4:-claude-sonnet-x}" "$3" >> "$1"; }
# 发一次 hook 事件:ev 事件 会话号 transcript [额外字段 JSON]
ev() {
  node -e 'const [e, s, f, x] = process.argv.slice(1); console.log(JSON.stringify(Object.assign({ hook_event_name: e, session_id: s, transcript_path: f, cwd: "/" }, x ? JSON.parse(x) : {})))' "$1" "$2" "$3" "${4:-}" | node "$GATE"
}
# 对 stdout 那段 JSON 求值:js "$out" '<JS 表达式,d 是解析后的对象>'
js() { printf '%s' "$1" | node -e 'let s = ""; process.stdin.on("data", (c) => s += c).on("end", () => { let d; try { d = JSON.parse(s); } catch (_) { process.exit(1); } process.exit(eval(process.argv[1]) ? 0 : 1); })' "$2"; }
act() { tail -1 "$LOGF" | awk -F'\t' '{print $8}'; }
col() { tail -1 "$LOGF" | awk -F'\t' -v c="$1" '{print $c}'; }
empty() { [ -z "$1" ]; }
is() { [ "$1" = "$2" ]; }
lines() { wc -l < "$1" | tr -d ' '; }

# 默认线 60%、没设窗口 = 按 20 万算:12 万 = 60.0% 到线,11.9 万 = 59.5% 没到
g_below_line_silent() {
  local F="$T/below.jsonl"; use "$F" 1 119000
  local out; out=$(ev Stop below000000a "$F"); need is $? 0; need empty "$out"; need is "$(act)" none
  out=$(ev PreToolUse below000000a "$F" '{"tool_name":"Bash"}'); need empty "$out"
}
g_remind_once() {
  local F="$T/remind.jsonl"; use "$F" 1 120000
  local out; out=$(ev Stop remind00000a "$F")
  need js "$out" '!d.decision && d.systemMessage.includes("该收尾了") && d.systemMessage.includes("60.0%")'; need is "$(act)" remind
  need grep -qx "$(printf 'remind00000a\t120000')" "$SEENF"
  out=$(ev Stop remind00000a "$F"); need empty "$out"; need is "$(act)" latched
}
g_step_again() {
  local F="$T/step.jsonl"; use "$F" 1 130000
  ev Stop step0000000a "$F" >/dev/null; need is "$(act)" remind
  use "$F" 2 150000; local out; out=$(ev Stop step0000000a "$F")       # 正好涨够一档(默认 2 万)
  need js "$out" 'd.systemMessage.includes("该收尾了")'; need is "$(act)" "remind+"
  use "$F" 3 155000; out=$(ev Stop step0000000a "$F"); need empty "$out"; need is "$(act)" latched
  use "$F" 4 175000; out=$(ESCORT_GATE_STEP=50000 ev Stop step0000000a "$F")   # 阴性对照:门槛抬到 5 万,涨 2.5 万不够
  need empty "$out"; need is "$(act)" latched
}
g_pretooluse_inject() {
  local F="$T/pre.jsonl"; use "$F" 1 130000
  local out; out=$(ESCORT_GATE_MINGROW=0 ev PreToolUse pre00000000a "$F" '{"tool_name":"Bash"}')
  need js "$out" 'd.hookSpecificOutput.hookEventName === "PreToolUse" && d.hookSpecificOutput.additionalContext.includes("--done") && d.hookSpecificOutput.additionalContext.includes("不拦") && !d.decision && !JSON.stringify(d).includes("permissionDecision")'
  need is "$(act)" inject
}
g_throttle() {
  local F="$T/thr.jsonl"; use "$F" 1 130000
  local one two n0; one=$(ESCORT_GATE_STEP=0 ev PreToolUse thr00000000a "$F" '{"tool_name":"Bash"}'); n0=$(lines "$LOGF")
  two=$(ESCORT_GATE_STEP=0 ev PreToolUse thr00000000a "$F" '{"tool_name":"Bash"}')
  need test -n "$one"; need empty "$two"; need is "$(lines "$LOGF")" "$n0"
  two=$(ESCORT_GATE_STEP=0 ESCORT_GATE_MINGROW=0 ev PreToolUse thr00000000a "$F" '{"tool_name":"Bash"}')   # 阴性对照:门槛拿掉必出声
  need test -n "$two"
}
g_dispatch_note() {
  local F="$T/disp.jsonl"; use "$F" 1 130000
  ev Stop disp0000000a "$F" >/dev/null
  local out; out=$(ev PreToolUse disp0000000a "$F" '{"tool_name":"Agent","tool_input":{"description":"铺下一批页面","subagent_type":"worker"}}')
  need js "$out" 'd.hookSpecificOutput.additionalContext.includes("铺下一批页面") && !d.decision'; need is "$(act)" dispatch
  out=$(ev PreToolUse disp0000000a "$F" '{"tool_name":"Bash"}'); need empty "$out"   # 阴性对照:普通调用被节流 / latched,不出声
}
g_errors_silent() {
  local out rc
  out=$(printf 'not json' | node "$GATE"); rc=$?; need is $rc 0; need empty "$out"
  out=$(ev Stop err00000000a "$T/no-such.jsonl"); rc=$?; need is $rc 0; need empty "$out"; need is "$(act)" "?/NO_TRANSCRIPT"
  printf 'garbage\n{"x":1}\n' > "$T/garbage.jsonl"
  out=$(ESCORT_GATE_PCT=0 ev Stop err00000000a "$T/garbage.jsonl"); rc=$?; need is $rc 0; need empty "$out"; need is "$(act)" "?/MISSING_USAGE"
  local F="$T/err.jsonl"; use "$F" 1 130000
  out=$(ev Stop err00000000b "$F" '{"stop_hook_active":true}'); need empty "$out"; need is "$(act)" active
  out=$(ev Stop err00000000b "$F" '{"agent_id":"a1"}'); need empty "$out"
  out=$(ev Stop err00000000b "$T/x/subagents/agent-1.jsonl"); need empty "$out"
  out=$(ESCORT_DATA_DIR=/dev/null/nope ev Stop err00000000c "$F"); rc=$?; need is $rc 0   # 数据目录写不进:不崩
  out=$(ev Notification err00000000b "$F"); need empty "$out"
}
g_window_env() {
  local F="$T/win.jsonl"; use "$F" 1 130000
  ev Stop win00000000a "$F" >/dev/null; need is "$(col 5)" 200000; need is "$(act)" remind
  local out; out=$(ESCORT_CONTEXT_WINDOW=1000000 ev Stop win00000000b "$F"); need empty "$out"
  need is "$(col 5)" 1000000; need is "$(col 6)" "13.0%"; need is "$(act)" none
  local B="$T/big.jsonl"; use "$B" 1 300000; use "$B" 2 310000         # 没设窗口但用过超 20 万 → 按 100 万猜
  out=$(ev Stop win00000000c "$B"); need empty "$out"; need is "$(col 5)" 1000000
}
g_long_prompt() {
  local i=0 sid p out bad=""
  for p in '护航 长跑 修登录页' '并驾:长跑' '长跑 护航 继续' '继续 长跑 护航' '长跑' '好 开始 长跑' '按推荐 开启长跑模式' '开始吧 护航长跑' "$(printf '护航\n护航 长跑 接着做')"; do
    i=$((i+1)); sid=$(printf 'lpos%08d' $i)
    out=$(node -e 'console.log(JSON.stringify({hook_event_name: "UserPromptSubmit", session_id: process.argv[1], prompt: process.argv[2]}))' "$sid" "$p" | node "$GATE")
    { [ -z "$out" ] && grep -qx "$sid" "$LONGF"; } || bad="$bad「$p」"
  done
  need is "$bad" ""
  bad=""
  for p in '长跑 先不做' '长跑模式怎么用' '不是长跑模式吗' '护航 修「长跑口令」的识别' '护航 接着做长跑模式第二格' '今天不长跑了'; do
    i=$((i+1)); sid=$(printf 'lneg%08d' $i)
    node -e 'console.log(JSON.stringify({hook_event_name: "UserPromptSubmit", session_id: process.argv[1], prompt: process.argv[2]}))' "$sid" "$p" | node "$GATE" >/dev/null
    ! grep -qx "$sid" "$LONGF" 2>/dev/null || bad="$bad「$p」"
  done
  need is "$bad" ""   # 阴性对照:否定句、问句、聊长跑、引号里举例都不记
}
g_long_cli() {
  node "$GATE" --is-long cli000000000; need is $? 1
  node "$GATE" --long cli000000000; node "$GATE" --long cli000000000
  node "$GATE" --is-long cli000000000; need is $? 0; need is "$(grep -c '^cli000000000$' "$LONGF")" 1
  node "$GATE" --unlong cli000000000; node "$GATE" --is-long cli000000000; need is $? 1
  CLAUDE_CODE_SESSION_ID=cli000000001-rest node "$GATE" --long; need grep -qx cli000000001 "$LONGF"
}
g_long_block() {
  local F="$T/long.jsonl"; use "$F" 1 130000; node "$GATE" --long long0000000a
  local out; out=$(ev Stop long0000000a "$F")
  need js "$out" 'd.decision === "block" && d.reason.includes("长跑") && d.reason.includes("--done") && d.reason.includes("AskUserQuestion") && d.systemMessage.includes("先收尾")'
  need is "$(act)" block/long
  out=$(ev PreToolUse long0000000a "$F" '{"tool_name":"Agent","tool_input":{"description":"下一格"}}'); need empty "$out"; need is "$(act)" latched/long
  out=$(ESCORT_GATE_LONG=/dev/null ev PreToolUse long0000000a "$F" '{"tool_name":"Agent","tool_input":{"description":"下一格"}}')
  need js "$out" 'd.hookSpecificOutput.additionalContext.includes("下一格")'   # 阴性对照:去掉长跑标记,派单那句照补
}
g_long_nudge() {
  local F="$T/nudge.jsonl"; use "$F" 1 50000; node "$GATE" --long nudge000000a
  local out; out=$(ev Stop nudge000000a "$F")
  need js "$out" 'd.decision === "block" && d.reason.includes("长跑续跑") && d.reason.includes("/goal")'; need is "$(act)" nudge/long
  out=$(ev Stop nudge000000a "$F" '{"stop_hook_active":true}'); need empty "$out"
  out=$(ESCORT_GATE_MINGROW=0 ev PreToolUse nudge000000a "$F" '{"tool_name":"Bash"}'); need empty "$out"
  printf '{"type":"attachment","attachment":{"type":"goal_status","met":false}}\n' >> "$F"
  out=$(ev Stop nudge000000a "$F"); need empty "$out"; need is "$(act)" goal/long
  out=$(ESCORT_GATE_LONG=/dev/null ev Stop nudge000000a "$F"); need empty "$out"; need is "$(act)" none
}
g_precompact() {
  local F="$T/cmp.jsonl"; use "$F" 1 130000
  local out; out=$(ev PreCompact cmp00000000a "$F" '{"trigger":"auto"}'); need empty "$out"; need is "$(act)" compact-pass/not-long
  node "$GATE" --long cmp00000000a
  out=$(ev PreCompact cmp00000000a "$F" '{"trigger":"auto"}')
  need js "$out" 'd.decision === "block" && d.reason.includes("还没收过尾")'; need is "$(act)" compact-block
  cp "$F" "$T/projects/p1/cmp00000000a-full.jsonl"
  local cur; cur=$(node "$GATE" --done cmp00000000a-full); need is $? 0; need is "$cur" 130000   # 不给 transcript,去 ESCORT_PROJECTS_DIR 找
  need grep -qx "$(printf 'cmp00000000a\t130000')" "$DONEF"
  out=$(ev PreCompact cmp00000000a "$F" '{"trigger":"auto"}'); need empty "$out"; need is "$(act)" compact-pass
  out=$(ESCORT_GATE_COMPACT_STALE=0 ev PreCompact cmp00000000a "$F" '{"trigger":"auto"}')   # 阴性对照:放行是收尾标记起的作用
  use "$F" 2 135000; out=$(ESCORT_GATE_COMPACT_STALE=0 ev PreCompact cmp00000000a "$F" '{"trigger":"auto"}'); need js "$out" 'd.decision === "block"'
  out=$(ev PreCompact cmp00000000a "$F" '{"trigger":"manual"}'); need empty "$out"; need is "$(act)" compact-manual
  out=$(ev PreCompact cmp00000000a "$F" '{"trigger":"auto","agent_id":"a1"}'); need empty "$out"
  use "$F" 3 185000; out=$(ESCORT_GATE_COMPACT_STALE=0 ev PreCompact cmp00000000a "$F" '{"trigger":"auto"}')
  need empty "$out"; need is "$(act)" compact-pass/overflow     # 18.5 万 > 20 万的 90%
  node "$GATE" --done nobody-here 2>/dev/null; need is $? 1
}
g_done_grace() {
  local F="$T/grace.jsonl"; use "$F" 1 130000
  ev Stop grace000000a "$F" >/dev/null; node "$GATE" --done grace000000a "$F" >/dev/null
  use "$F" 2 160000; local out; out=$(ev Stop grace000000a "$F"); need empty "$out"; need is "$(act)" done
  out=$(ESCORT_GATE_GRACE=0 ev Stop grace000000a "$F"); need js "$out" 'd.systemMessage.includes("该收尾了")'   # 阴性对照
}
g_after_compact() {
  local F="$T/ac.jsonl"; use "$F" 1 130000; node "$GATE" --long ac0000000000
  ev Stop ac0000000000 "$F" >/dev/null; node "$GATE" --done ac0000000000 "$F" >/dev/null
  local out; out=$(ev Stop ac0000000000 "$F"); need empty "$out"
  out=$(ev SessionStart ac0000000000 "$F" '{"source":"compact"}')
  need test -n "$out"; need grep -q '压缩前的到线提醒作废' <<<"$out"; need is "$(act)" after-compact
  need grep -qx "$(printf 'ac0000000000\t-1')" "$SEENF"; need grep -qx "$(printf 'ac0000000000\t-1')" "$DONEF"
  out=$(ev Stop ac0000000000 "$F"); need js "$out" 'd.decision === "block" && d.reason.includes("到线了")'   # 从头算:第一次到线,不是 latched / done
  out=$(ev PreCompact ac0000000000 "$F" '{"trigger":"auto"}'); need js "$out" 'd.decision === "block"'
  out=$(ev SessionStart ac0000000000 "$F" '{"source":"startup"}'); need empty "$out"
  out=$(ev SessionStart ac0000000000 "$F" '{"source":"compact","agent_id":"a1"}'); need empty "$out"
}
g_snapshot() {
  local R="$T/repo" out
  mkdir -p "$R" && git -C "$R" init -q && git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "首个提交"
  local D1="$((2000+1))-01-02" D2="$((2000+1))-03-04"
  printf '# 进度\n\n## %s 旧的那条\n旧内容\n\n## %s 最新这条\n新内容\n' "$D1" "$D2" > "$R/progress.md"
  printf -- '- [ ] 大活甲\n  - [x] 子一\n  - [ ] 子二\n' > "$R/task_plan.md"
  snap() { node -e 'console.log(JSON.stringify(Object.assign({hook_event_name: "SessionStart", source: "compact", cwd: process.argv[1], session_id: process.argv[2]}, process.argv[3] ? JSON.parse(process.argv[3]) : {})))' "$1" "$2" "${3:-}" | bash "$SNAP"; }
  out=$(snap "$R" snap00000000a)
  need grep -q '^\[压缩后快照\]' <<<"$(head -1 <<<"$out")"; need is "$(tail -1 <<<"$out")" "【快照完】"
  need grep -q '首个提交' <<<"$out"; need grep -q '新内容' <<<"$out"; need test -z "$(grep '旧内容' <<<"$out")"
  need grep -q '大活甲' <<<"$out"; need test -z "$(grep '对照 task_plan' <<<"$out")"
  node "$GATE" --long snap00000000a; out=$(snap "$R" snap00000000a); need grep -q '对照 task_plan 未完格接着干' <<<"$out"
  mkdir -p "$T/notgit"; out=$(snap "$T/notgit" snap00000000a); need is $? 0; need empty "$out"
  out=$(snap "$R" snap00000000a '{"agent_id":"a1"}'); need empty "$out"
  out=$(printf 'not json' | bash "$SNAP"); need is $? 0; need empty "$out"
}

for g in g_below_line_silent g_remind_once g_step_again g_pretooluse_inject g_throttle g_dispatch_note g_errors_silent g_window_env \
         g_long_prompt g_long_cli g_long_block g_long_nudge g_precompact g_done_grace g_after_compact g_snapshot; do group "$g"; done
echo "----"
if [ -z "$failed" ]; then echo "PASS $passed/$total"; exit 0; fi
echo "FAIL $passed/$total:$failed"; exit 1
