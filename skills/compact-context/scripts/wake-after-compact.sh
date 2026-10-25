#!/usr/bin/env bash
# wake-after-compact.sh —— 用户手敲 /compact 压完,Claude Code 通常不会自己开下一轮,活就停了。
#   后台任务结束会叫醒会话,所以:给用户 /compact 命令之前,会话用 Bash 的 run_in_background 起本脚本;
#   它盯本会话记录文件,见到新的压缩点就退出,退出那一下把会话叫醒,会话按打印的话读存档接着干。
#
# 怎么跑(会话里用 Bash 工具、run_in_background: true):
#   bash ~/.claude/skills/compact-context/scripts/wake-after-compact.sh <压缩前存档绝对路径>
# 环境:CLAUDE_CODE_SESSION_ID(Bash 里自带);WAKE_TRANSCRIPT 可直接指定记录文件(测试用);WAKE_MAX_SEC 默认 7200。
# 退出码:0 见到压缩点;2 找不到记录文件;3 等满时限没见到(用户没压,叫醒后照常问他)。
set -u
ARCHIVE="${1:-}"
MAX="${WAKE_MAX_SEC:-7200}"
F="${WAKE_TRANSCRIPT:-}"
if [ -z "$F" ]; then
  SID="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$SID" ] || { echo "压完叫醒: 拿不到会话号,没法盯" >&2; exit 2; }
  F="$(find "$HOME/.claude/projects" -maxdepth 2 -name "$SID.jsonl" 2>/dev/null | head -1)"
fi
[ -n "$F" ] && [ -f "$F" ] || { echo "压完叫醒: 找不到本会话记录文件" >&2; exit 2; }

START="$(stat -c %s "$F" 2>/dev/null || stat -f %z "$F")"
waited=0
while [ "$waited" -lt "$MAX" ]; do
  if tail -c +"$((START + 1))" "$F" | grep -q '"subtype":"compact_boundary"'; then
    sleep 3   # 压缩后若有 hook 往会话里写内容,等它写完再叫醒
    echo "[压完叫醒] 压缩已完成。按 skill compact-context「压完之后第一轮」接着干${ARCHIVE:+:先读 $ARCHIVE}"
    exit 0
  fi
  sleep 5; waited=$((waited + 5))
done
echo "[压完叫醒] 等了 ${MAX} 秒没见到压缩,用户可能没敲 /compact"
exit 3
