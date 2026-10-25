#!/usr/bin/env node
// heartbeat.js —— 挂在 SubagentStart / SubagentStop 两个 hook 上,子 agent 每次启停追加一行。
// 日志:~/.claude/escort-heartbeat.log(可用环境变量 ESCORT_HEARTBEAT_LOG 改),制表符五列:
//   ISO时间 / 事件 / 会话前12位 / agent类型 / agent_id
// 任何异常都 exit 0、不往 stdout 打字:hook 出错不能打断会话。

const fs = require('fs');
const os = require('os');
const path = require('path');

const LOG = process.env.ESCORT_HEARTBEAT_LOG ||
  path.join(os.homedir(), '.claude', 'escort-heartbeat.log');

const MAX_BYTES = 2 * 1024 * 1024;   // 超过就砍到末 500 行,防无限长
const KEEP_LINES = 500;

function clean(v, n) {
  return String(v == null ? '-' : v).replace(/[\r\n\t]/g, ' ').slice(0, n) || '-';
}

function rotate() {
  try {
    if (fs.statSync(LOG).size <= MAX_BYTES) return;
    const lines = fs.readFileSync(LOG, 'utf8').split('\n');
    fs.writeFileSync(LOG, lines.slice(-KEEP_LINES).join('\n'));
  } catch (_) { /* 没有文件 / 读不动都不算事,下面照样追加 */ }
}

function write(raw) {
  try {
    const ev = process.argv[2] || '?';
    let p = {};
    try { p = JSON.parse(raw) || {}; } catch (_) { p = {}; }

    const line = [
      new Date().toISOString(),
      clean(ev, 32),
      clean(p.session_id, 12),
      clean(p.agent_type || p.subagent_type, 48),
      clean(p.agent_id || p.subagent_id, 64),
    ].join('\t') + '\n';

    rotate();
    fs.appendFileSync(LOG, line);
  } catch (_) { /* 出错也 exit 0 */ }
  process.exit(0);
}

let raw = '';
let done = false;
const finish = () => { if (!done) { done = true; write(raw); } };

process.stdin.on('data', (c) => { raw += c; });
process.stdin.on('end', finish);
process.stdin.on('error', finish);

setTimeout(finish, 2000).unref();
