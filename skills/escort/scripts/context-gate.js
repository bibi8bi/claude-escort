#!/usr/bin/env node
// context-gate.js —— 上下文闸:读会话记录(transcript)算「当前上下文占窗口几成」,到线提醒收尾;
//   长跑会话(用户说了「护航 长跑」之类的口令)到线不换窗口:先收尾、再放 Claude Code 自动压缩、压完接着干。
//
// 干什么(同一个文件,按 stdin 里的 hook_event_name 自己分路):
//   · Stop / PreToolUse —— 到线提醒一次,之后占用每涨一档(ESCORT_GATE_STEP)再提醒一次。
//       普通会话:只给一句「该收尾了」,不拦(Stop 只在屏上打一行,PreToolUse 往上下文补一句);
//       过线后再派子 agent(Agent / Task)补一句派单提醒。
//       长跑会话:Stop 回 decision:block 逼它先收尾,PreToolUse 注入同一段话;不补派单提醒(长跑本来就要一直派活)。
//       PreToolUse 一窗几百次,进门先做长度节流:transcript 没比上次真算时长 ESCORT_GATE_MINGROW 字节就直接退出。
//   · Stop(长跑会话、没到线、正要停、没有在跑的 /goal)—— 拦一次叫它接下一格;被拦出来那轮放行,所以每次想停只拦一回。
//   · PreCompact(挂 matcher auto)—— 只守长跑会话:没收过尾、或收尾之后又涨了 ESCORT_GATE_COMPACT_STALE → 挡这次自动压缩;
//       占用超过放行线一律放行(见下「放行线的来历」);手动 /compact、子 agent、非长跑会话一律放行。
//   · SessionStart(挂 matcher compact)—— 压缩之后把本会话的提醒计数和收尾标记归零,往上下文打一句「压缩前的提醒作废」。
//   · UserPromptSubmit —— 从用户这句话的头 3 个非空行认长跑口令,认出就记标记;stdout 不写字。
//   · 命令行:--done [会话号] [transcript]  记「已收尾」(收尾 = 写进度文件 + 提交自己的改动),stdout 打当前占用;
//             --long / --unlong [会话号]    手动开 / 关长跑;--is-long [会话号]  是长跑 exit 0,不是 exit 1。
//             会话号不给就用环境变量 CLAUDE_CODE_SESSION_ID(Claude Code 给自己跑的命令都带它)。
//
// 怎么挂:见 README「可选:长跑 hook」,五个挂点全是同一行命令 `node <本文件>`。Stop / PreToolUse / PreCompact 不许设 async,
//   async 的 hook 回不了 block、注入不了上下文。
//
// 口径:当前占用 = 最后一次 API 响应的 input + cache_read + cache_creation + output,
//   再加那次响应之后刚回来、还没进用量的 tool_result(ASCII 4 字符 1 token,非 ASCII 每字 1.5 token,图片一张按 1600);
//   最后一个压缩点(compact_boundary)之后还没有新响应 → 按压缩点记的 postTokens 算。占比 = 当前占用 ÷ 窗口。
//   窗口:设了 ESCORT_CONTEXT_WINDOW 就用它;没设就猜 —— 本会话有过超 20 万的响应 = 必是大窗口,按 1000000;其余一律 200000。
//
// 环境变量(全可不设):
//   ESCORT_CONTEXT_WINDOW      窗口大小,token。用 100 万窗口的模型请设 1000000,不然没超 20 万之前都按 20 万算
//   ESCORT_GATE_PCT            线,百分数,默认 60;设 0 = 必触发(用例用)
//   ESCORT_GATE_STEP           到线后再提醒的涨幅,token,默认 20000;设 0 = 每次都提醒
//   ESCORT_GATE_GRACE          普通会话 --done 之后多涨多少 token 以内不再提醒,默认窗口的 5%(20 万窗口 = 10000)
//   ESCORT_GATE_LONG_GRACE     长跑会话同上,默认窗口的 10%
//   ESCORT_GATE_COMPACT_STALE  长跑会话收尾之后涨多少以内算「收尾新鲜」、放行自动压缩,默认窗口的 10%
//                              (这三个写了绝对值就用绝对值,不再按窗口算)
//   ESCORT_GATE_PASS_AT        PreCompact 放行线,token;默认 min(窗口 × 0.9, 窗口 − 45000)
//   ESCORT_GATE_MINGROW        PreToolUse 长度节流门槛,字节,默认 100000;设 0 = 每次都真算
//   ESCORT_DATA_DIR            数据文件目录,默认 <配置目录>/escort/(配置目录 = CLAUDE_CONFIG_DIR,没设就是 ~/.claude);
//                              下面五个可以单个改道:
//   ESCORT_GATE_SEEN(seen.txt 提醒过的占用)ESCORT_GATE_DONE(done.txt 收尾时的占用)ESCORT_GATE_LONG(long.txt 长跑会话)
//   ESCORT_GATE_CURSOR(cursor.txt 节流游标)ESCORT_GATE_LOG(gate.log 日志)
//   ESCORT_PROJECTS_DIR        --done 没给 transcript 时去哪找,默认 <配置目录>/projects
//
// 放行线的来历:按 Claude Code 2.1.310 的门槛,自动压缩点 = 窗口 − 20000 − 13000,封死点(再大请求直接失败)
//   = 窗口 − 20000 − 3000;20 万窗口分别是 16.7 万、17.7 万。放行线取 min(窗口 × 0.9, 窗口 − 45000),
//   20 万窗口 = 15.5 万,比自动压缩点低一截,不会把会话挡到封死。换 Claude Code 版本这几个数可能变,变了改 ESCORT_GATE_PASS_AT。
//   副作用:20 万窗口下自动压缩一来多半已过放行线,守门基本只在大窗口(或自动压缩点调低了)时起作用。
//   数据文件超过 2MB 自动截到最后 500 行。
//
// 日志(gate.log):制表符 8 列 —— ISO时间 / 会话号前12位 / 模型 / 当前占用 / 窗口 / 占比 / 线 / 动作
//   动作:none(没到线)| remind / remind+(普通会话 Stop 到线 / 又涨一档)| block / block+(长跑会话 Stop)
//        | inject / inject+(PreToolUse)| dispatch(过线后派单,只补派单那句)| latched(到线但没涨够一档)
//        | done(收尾宽限内不催)| active(stop_hook_active 放行)| nudge(长跑续跑拦了一次)| goal(有 /goal 在跑,不拦)
//        | compact-block | compact-pass | compact-pass/not-long | compact-pass/overflow | compact-manual
//        | after-compact | mark-long | unmark-long | mark-done | ?/诊断码。长跑会话的动作带后缀 /long。
//   PreToolUse 被长度节流挡掉的那些不写日志。
//
// 铁规:①只读 transcript,只写自己的数据文件,不读业务文件、不改配置;②挂成 hook 时任何异常 exit 0、stdout 为空
//   (hook 非零退出会打断会话,stdout 会被当成指令);③没到线时 stdout 一个字不写 —— 例外只有长跑续跑那一拦
//   和压缩后那一句;④stop_hook_active=true(这一轮就是被上一次 block 逼出来的)直接放行,不自己追自己。
//
// 已知局限:
//   · 主会话派完子 agent 后自己干等、期间一个工具都不调,Stop / PreToolUse 都不响;PreCompact 只守门不催。
//   · 窗口靠猜:100 万窗口的会话在用到 20 万之前会被当成 20 万窗口,提前提醒。设 ESCORT_CONTEXT_WINDOW 就准了。
//   · 占用是估的:tool_result 按字符折算,跟 Claude Code 自己的数差几千到两万 token。
//   · 长跑口令靠正则认:只认「方式词 + 长跑」挨着,或整行就是「长跑 / 长跑模式 / 开启长跑」;没带方式词又不是整行的
//     (「好 开始 长跑」)不认;没加引号聊「护航长跑那次」会被误认。
//   · PreCompact 被挡之后,Claude Code 每次发请求前都会再试一次自动压缩,没有冷却期;挡了对话不压、继续跑。

const fs = require('fs');
const os = require('os');
const path = require('path');

const num = (k, d) => { const n = Number(process.env[k]); return process.env[k] !== undefined && process.env[k] !== '' && Number.isFinite(n) && n >= 0 ? n : d; };
const PCT = num('ESCORT_GATE_PCT', 60);
const STEP = num('ESCORT_GATE_STEP', 20000);
const GRACE = num('ESCORT_GATE_GRACE', -1);              // -1 = 没设,按窗口比例算
const LONG_GRACE = num('ESCORT_GATE_LONG_GRACE', -1);
const COMPACT_STALE = num('ESCORT_GATE_COMPACT_STALE', -1);
const PASS_AT = num('ESCORT_GATE_PASS_AT', -1);
const ratio = (v, k, win) => (v >= 0 ? v : Math.round(k * win));
const passAt = (win) => (PASS_AT >= 0 ? PASS_AT : Math.min(win * 0.9, win - 45000));
const MINGROW = num('ESCORT_GATE_MINGROW', 100000);
const WIN_ENV = num('ESCORT_CONTEXT_WINDOW', 0);
const CONF = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const DIR = process.env.ESCORT_DATA_DIR || path.join(CONF, 'escort');
const SEEN = process.env.ESCORT_GATE_SEEN || path.join(DIR, 'seen.txt');
const DONE = process.env.ESCORT_GATE_DONE || path.join(DIR, 'done.txt');
const LONG = process.env.ESCORT_GATE_LONG || path.join(DIR, 'long.txt');
const CURSOR = process.env.ESCORT_GATE_CURSOR || path.join(DIR, 'cursor.txt');
const LOG = process.env.ESCORT_GATE_LOG || path.join(DIR, 'gate.log');
const PROJECTS = process.env.ESCORT_PROJECTS_DIR || path.join(CONF, 'projects');
const SELF = `node ${JSON.stringify(__filename)}`;   // 路径带空格也能原样粘贴

const SMALL_WIN = 200000;
const BIG_WIN = 1000000;
const IMG_TOK = 1600;      // 一张图估多少 token
const MAX_BYTES = 2 * 1024 * 1024;
const KEEP_LINES = 500;
const MAX_SCAN_BYTES = 64 * 1024 * 1024;
const STDIN_TIMEOUT_MS = 2000;
const DISPATCH_TOOLS = new Set(['Agent', 'Task']);

// 长跑口令:①「长跑」和方式词挨着,谁先谁后都认(引号里举的例子先剥掉,只看每行前 40 个字和末 20 个字);
//   ②整行就是「长跑 / 长跑模式 / 开启·进入·切到长跑(模式)」,前后只许有空白和标点(问号不算)。
const WAYS = '(?:全程护航|进阶并驾|护航|并驾|全力)';
const LONG_RE = new RegExp(`^${WAYS}[\\s:：]*长跑`);
const LONG_PAIR_RE = new RegExp(`${WAYS}[\\s:：]*长跑|长跑(?:模式)?[\\s:：]*${WAYS}`, 'g');
const LONG_LINE_RE = /^[\s,，。.;；:：!！、~…]*(?:开启|进入|切到)?长跑(?:模式)?[\s,，。.;；:：!！、~…]*$/;
const LONG_QUOTE_RE = /「[^」]*」|『[^』]*』|“[^”]*”|"[^"]*"|`[^`]*`/g;
const LONG_HEAD = 40;
const LONG_TAIL = 20;

// ── 话术 ──
const WRAP = `收尾 = 把做到哪、下一步是什么写进进度文件(progress.md 之类),只提交你自己改的文件(git commit -- <路径>),收完跑 ${SELF} --done`;
const LINE = (pctStr, cur) => `⏰ 上下文已用 ${pctStr}(${cur} token),过了 ${PCT}% 线 —— 该收尾了`;
const MSG = (pctStr, cur, win, again) =>
  `[context-gate] ${again ? '又涨了一档' : '到线了'}:当前上下文 ${pctStr}(${cur} / 窗口 ${win} token),过了 ${PCT}% 线,该收尾了。${WRAP}。这只是提醒,不拦;接不接着干听用户的。`;
const LINE_LONG = (pctStr, cur) => `⏰ 长跑:上下文已用 ${pctStr}(${cur} token),到 ${PCT}% 线 —— 先收尾再继续`;
const MSG_LONG = (pctStr, cur, win, again) => [
  `[context-gate·长跑] ${again ? '又涨了一档,再催一次' : '到线了'}:当前上下文 ${pctStr}(${cur} / 窗口 ${win} token),线 ${PCT}%。`,
  `本会话是长跑会话:不换窗口,先收尾、再让 Claude Code 自动压缩、压完接着干。`,
  `① 到线前已经开始的活先安全停下:收子 agent 回报、给改完的东西跑检查;不开新的一格。`,
  `② ${WRAP}。记上收尾之后,自动压缩才放行。`,
  `③ 收完直接接着干下一格,不等用户;压缩完 hook 会把 git 状态和进度最新一条塞回来。`,
  `· 要用户拍板的事用 AskUserQuestion 弹窗问,别在正文里问完就停。`,
  `· 收尾之后再涨 ${ratio(LONG_GRACE, 0.1, win)} token 会再催一次。`,
].join('\n');
const LINE_NUDGE = '⏩ 长跑:没设 /goal —— 接下一格,别停';
const MSG_NUDGE = (cur) => [
  `[context-gate·长跑续跑] 长跑会话这一轮正要停(当前 ${cur} token,没到线),也没有在跑的 /goal,拦这一次。`,
  `· 手上这件还没写进度、没提交 → 先收尾:${WRAP}。`,
  `· 对照 task_plan 接下一格没做完的活。`,
  `· 下一格要用户拍板 → 用 AskUserQuestion 弹窗问,别在正文里问完就停。`,
  `· 真没有能推的格(剩下的都在等用户 / 等外部,或用户说过到此为止)→ 一句话说清为什么停,然后结束;这次不再拦。`,
  `· 想让会话一直跑:开窗时敲 /goal <收尾条件>,有 goal 在跑时不拦。`,
].join('\n');
const DISPATCH_NOTE = (pctStr, inp) =>
  `[context-gate] 已过 ${PCT}% 线(${pctStr}),你在派子 agent「${clean(inp.description, 60)}」(${clean(inp.subagent_type, 30)})。这次不拦;下次派之前想一下:验收已改完的东西照派,新活建议先收尾、开新会话再做。`;
const DISPATCH_LINE = (pctStr, inp) => `⏰ 已过 ${PCT}% 线(${pctStr}),又派了子 agent「${clean(inp.description, 60)}」`;
const AFTER_COMPACT_NOTE = `[context-gate] 本会话上下文刚被压缩:压缩前的到线提醒作废,占用从头算;摘要里抄来的旧占用数别再引用。再到 ${PCT}% 线会重新提醒。`;

function clean(v, n) { return String(v == null ? '-' : v).replace(/[\r\n\t]/g, ' ').slice(0, n) || '-'; }

function rotate(f) {
  try {
    if (fs.statSync(f).size <= MAX_BYTES) return;
    fs.writeFileSync(f, fs.readFileSync(f, 'utf8').split('\n').slice(-KEEP_LINES).join('\n'));
  } catch (_) { /* 铁规 2 */ }
}

function append(f, s) {
  fs.mkdirSync(path.dirname(f), { recursive: true });
  rotate(f);
  fs.appendFileSync(f, s);
}

function log(cols) { try { append(LOG, cols.join('\t') + '\n'); } catch (_) { /* 铁规 2 */ } }
const blank = (now, sid, act) => log([now, sid, '-', '0', '0', '-', PCT + '%', act]);

function emit(obj) { try { fs.writeSync(1, JSON.stringify(obj) + '\n'); } catch (_) { /* 铁规 2 */ } }

function readTranscript(f) {
  const st = fs.statSync(f);
  if (st.size <= MAX_SCAN_BYTES) return fs.readFileSync(f, 'utf8');
  const fd = fs.openSync(f, 'r');
  try {
    const buf = Buffer.alloc(MAX_SCAN_BYTES);
    fs.readSync(fd, buf, 0, MAX_SCAN_BYTES, st.size - MAX_SCAN_BYTES);
    const text = buf.toString('utf8');
    return text.slice(text.indexOf('\n') + 1);
  } finally { try { fs.closeSync(fd); } catch (_) { /* 铁规 2 */ } }
}

const parse = (l) => { try { return JSON.parse(l); } catch (_) { return null; } };
const hasUsage = (d) => { const u = d && d.message && d.message.usage; return !!(u && typeof u === 'object' && Object.keys(u).length > 0); };

// 当前占用(口径见文件头)。返回 turns=0 = 一次响应都没有,各调用方当「读不到」处理。
function scan(f) {
  const lines = readTranscript(f).split('\n');
  const resp = new Map();
  const models = new Set();
  lines.forEach((raw, idx) => {
    if (raw.indexOf('"usage"') === -1) return;
    const d = parse(raw.trim());
    if (!hasUsage(d)) return;
    const m = d.message, u = m.usage;
    const key = m.id || ('noid#' + idx);
    const e = resp.get(key) || { i: 0, o: 0 };
    e.i = Math.max(e.i, (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0));
    e.o = Math.max(e.o, u.output_tokens || 0);
    resp.set(key, e);
    if (m.model) models.add(String(m.model));
  });
  let peak = 0, cur = 0;
  for (const e of resp.values()) peak = Math.max(peak, e.i + e.o);
  for (const e of [...resp.values()].reverse()) if (e.i + e.o > 0) { cur = e.i + e.o; break; }
  if (cur === 0) cur = peak;
  let chars = 0, wide = 0, imgs = 0;
  if (resp.size > 0) {
    let last = -1;
    for (let n = lines.length - 1; n >= 0 && last < 0; n--) if (lines[n].indexOf('"usage"') !== -1 && hasUsage(parse(lines[n]))) last = n;
    for (let n = lines.length - 1; n > last; n--) {            // 压缩点之后还没新响应:按 postTokens 算
      if (lines[n].indexOf('"compact_boundary"') === -1) continue;
      const d = parse(lines[n]);
      if (!d || d.type !== 'system' || d.subtype !== 'compact_boundary') continue;
      cur = Number(d.compactMetadata && d.compactMetadata.postTokens) || 0;
      last = n;
      break;
    }
    for (let n = last + 1; last >= 0 && n < lines.length; n++) {
      if (lines[n].indexOf('"tool_result"') === -1) continue;
      const d = parse(lines[n]);
      const c = d && d.type === 'user' && d.message && d.message.content;
      if (!Array.isArray(c)) continue;
      for (const b of c) {
        if (!b || b.type !== 'tool_result') continue;
        const c2 = Array.isArray(b.content) ? b.content.map((x) => (x && x.type === 'image') ? (imgs++, { type: 'image' }) : x) : b.content;
        const s = JSON.stringify(c2 == null ? '' : c2);
        for (let k = 0; k < s.length; k++) { if (s.charCodeAt(k) > 127) wide++; else chars++; }
      }
    }
  }
  cur += Math.ceil(chars / 4 + wide * 1.5) + imgs * IMG_TOK;
  return { cur, peak, turns: resp.size, models: [...models] };
}

function windowOf(r) {
  if (WIN_ENV > 0) return WIN_ENV;
  if (r.models.some((m) => /\[1m\]|-1m\b/i.test(m))) return BIG_WIN;
  return r.peak > SMALL_WIN ? BIG_WIN : SMALL_WIN;   // 用过超 20 万 = 必是大窗口;其余猜不准一律按 20 万
}

function measure(tp, now, sid) {
  let r;
  try { r = scan(String(tp)); } catch (_) { blank(now, sid, '?/NO_TRANSCRIPT'); return null; }
  const model = r.models.map((x) => x.replace('claude-', '')).sort().join(',') || '?';
  if (r.turns === 0) { log([now, sid, model, '0', '0', '-', PCT + '%', '?/MISSING_USAGE']); return null; }
  r.win = windowOf(r);
  r.pct = r.cur / r.win * 100;
  r.pctStr = r.pct.toFixed(1) + '%';
  r.head = [now, sid, model, String(r.cur), String(r.win), r.pctStr, PCT + '%'];
  return r;
}

function isMain(p) {
  const id = p.agent_id || p.subagent_id || '';
  if (id && id !== 'claude-code') return false;
  return !/[\\/]subagents[\\/]agent-[^\\/]*\.jsonl$/.test(String(p.transcript_path || ''));
}

// 读「会话号 \t 数」那种数据文件,取这个会话最后一行的数;没有返回 -1
function lastVal(f, sid) {
  let v = -1;
  try {
    for (const l of fs.readFileSync(f, 'utf8').split('\n')) {
      const c = l.split('\t');
      if (c[0] === sid) v = Number(c[1]);
      if (!Number.isFinite(v)) v = -1;
    }
  } catch (_) { /* 没有文件 = 没记过 */ }
  return v;
}

// PreToolUse 长度节流:transcript 比上次真算时多 MINGROW 字节才再算。读不出一律返回 true(宁可多算一次)。
function grownEnough(sid, tp) {
  if (MINGROW === 0) return true;
  let size;
  try { size = fs.statSync(tp).size; } catch (_) { return true; }
  const prev = lastVal(CURSOR, sid);
  if (prev >= 0 && size < prev + MINGROW) return false;
  try { append(CURSOR, sid + '\t' + size + '\n'); } catch (_) { /* 铁规 2 */ }
  return true;
}

function isLong(sid) {
  try { return fs.readFileSync(LONG, 'utf8').split('\n').some((l) => l.trim() === sid); } catch (_) { return false; }
}

function markLong(sid) {
  if (!sid || sid === '-' || isLong(sid)) return;
  append(LONG, sid + '\n');
  blank(new Date().toISOString(), sid, 'mark-long');
}

function unmarkLong(sid) {
  if (!sid || sid === '-' || !isLong(sid)) return;
  const keep = fs.readFileSync(LONG, 'utf8').split('\n').filter((l) => l.trim() && l.trim() !== sid);
  fs.writeFileSync(LONG, keep.length ? keep.join('\n') + '\n' : '');
  blank(new Date().toISOString(), sid, 'unmark-long');
}

// /goal 在跑 = transcript 里最后一条 goal_status 附件 met=false。读不出按「有 goal」算,宁可不拦。
function goalActive(tp) {
  let met = null;
  try {
    for (const l of readTranscript(tp).split('\n')) {
      if (l.indexOf('"goal_status"') < 0) continue;
      const a = (parse(l) || {}).attachment;
      if (a && a.type === 'goal_status') met = a.met === true;
    }
  } catch (_) { return true; }
  return met === false;
}

// Stop / PreToolUse
function run(p, sid, now) {
  const pre = p.hook_event_name === 'PreToolUse';
  const dispatch = pre && DISPATCH_TOOLS.has(String(p.tool_name || ''));
  const inp = (p.tool_input && typeof p.tool_input === 'object') ? p.tool_input : {};
  if (!isMain(p)) { if (!pre) blank(now, sid, '?/SUBAGENT'); return; }
  if (p.stop_hook_active === true) { blank(now, sid, 'active'); return; }
  const tp = p.transcript_path;
  if (!tp) { if (!pre) blank(now, sid, '?/NO_PATH'); return; }
  if (pre && !dispatch && !grownEnough(sid, String(tp))) return;

  const r = measure(tp, now, sid);
  if (!r) return;
  const long = isLong(sid);
  const tag = long ? '/long' : '';

  if (r.pct < PCT) {
    if (long && !pre) {                                       // 长跑续跑:线下想停,拦一次
      if (goalActive(String(tp))) { log(r.head.concat(['goal/long'])); return; }
      log(r.head.concat(['nudge/long']));
      emit({ decision: 'block', reason: MSG_NUDGE(r.cur), systemMessage: LINE_NUDGE });
      return;
    }
    log(r.head.concat(['none' + tag]));
    return;
  }

  const prev = lastVal(SEEN, sid);
  const again = prev >= 0;
  const doneAt = lastVal(DONE, sid);
  const quiet = doneAt >= 0 && r.cur < doneAt + (long ? ratio(LONG_GRACE, 0.1, r.win) : ratio(GRACE, 0.05, r.win));
  const due = !quiet && !(again && r.cur < prev + STEP);
  const note = dispatch && !long;
  if (!due && !note) { log(r.head.concat([(quiet ? 'done' : 'latched') + tag])); return; }
  if (due) { try { append(SEEN, sid + '\t' + r.cur + '\n'); } catch (_) { /* 铁规 2:记不上也照提醒这一次 */ } }

  const plus = again ? '+' : '';
  const act = due ? (pre ? 'inject' : (long ? 'block' : 'remind')) + plus : '';
  log(r.head.concat([(note ? (act ? act + '/dispatch' : 'dispatch') : act) + tag]));
  const body = due ? (long ? MSG_LONG : MSG)(r.pctStr, r.cur, r.win, again) : '';
  const sys = due ? (long ? LINE_LONG : LINE)(r.pctStr, r.cur) : DISPATCH_LINE(r.pctStr, inp);
  if (pre) {
    const ctx = [body, note ? DISPATCH_NOTE(r.pctStr, inp) : ''].filter(Boolean).join('\n\n');
    emit({ systemMessage: sys, hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: ctx } });
  } else if (long) {
    emit({ decision: 'block', reason: body, systemMessage: sys });
  } else {
    emit({ systemMessage: sys });                             // 普通会话:屏上一行,不拦
  }
}

// PreCompact:放行 = stdout 空;挡 = {"decision":"block"}
function compactGate(p, sid, now) {
  if (!isMain(p)) return;
  if (String(p.trigger || '') !== 'auto') { blank(now, sid, 'compact-manual'); return; }
  if (!isLong(sid)) { blank(now, sid, 'compact-pass/not-long'); return; }
  if (!p.transcript_path) { blank(now, sid, '?/NO_PATH'); return; }
  const r = measure(p.transcript_path, now, sid);
  if (!r) return;
  if (r.cur > passAt(r.win)) { log(r.head.concat(['compact-pass/overflow'])); return; }
  const doneAt = lastVal(DONE, sid);
  if (doneAt >= 0 && r.cur - doneAt <= ratio(COMPACT_STALE, 0.1, r.win)) { log(r.head.concat(['compact-pass'])); return; }
  const since = doneAt >= 0 ? `最近一次收尾在占用 ${doneAt},之后又涨了 ${r.cur - doneAt}` : `还没收过尾(当前占用 ${r.cur})`;
  log(r.head.concat(['compact-block']));
  emit({ decision: 'block', reason: `[context-gate] 拦下这次自动压缩:本会话${since}。先收尾:${WRAP};记上之后压缩会再来。占用超过 ${Math.round(passAt(r.win))} token 一律放行。` });
}

// SessionStart(compact):提醒计数、收尾标记归零(记 -1 = 当作没有),往上下文打一句
function afterCompact(p, sid, now) {
  if (!isMain(p) || String(p.source || '') !== 'compact' || sid === '-') return;
  try { append(SEEN, sid + '\t-1\n'); append(DONE, sid + '\t-1\n'); } catch (_) { /* 铁规 2 */ }
  blank(now, sid, 'after-compact');
  try { fs.writeSync(1, AFTER_COMPACT_NOTE + '\n'); } catch (_) { /* 铁规 2 */ }
}

function isLongLine(x) {
  if (LONG_RE.test(x)) return true;
  const s = x.replace(LONG_QUOTE_RE, '');
  const edge = (m) => m.index < LONG_HEAD || m.index + m[0].length > s.length - LONG_TAIL;
  for (const m of s.matchAll(LONG_PAIR_RE)) if (edge(m)) return true;
  return LONG_LINE_RE.test(s);
}

// UserPromptSubmit:认长跑口令,stdout 一个字不写
function recognizeLong(p, sid) {
  if (!isMain(p) || sid === '-') return;
  const lines = String(p.prompt || '').split('\n').map((x) => x.trim()).filter(Boolean).slice(0, 3);
  if (lines.some(isLongLine)) markLong(sid);
}

function findTranscript(sidFull) {
  for (const d of fs.readdirSync(PROJECTS)) {
    const f = path.join(PROJECTS, d, String(sidFull) + '.jsonl');
    if (fs.existsSync(f)) return f;
  }
  return '';
}

// --done:按同一口径记下收尾时的占用。算不出 exit 1(这是给人和脚本跑的命令,不是 hook)
function markDone(sidFull, tp) {
  const sid = clean(sidFull, 12);
  if (!sidFull || sid === '-') throw new Error('no session id');
  const r = scan(tp || findTranscript(sidFull));
  if (r.turns === 0) throw new Error('no usage');
  append(DONE, sid + '\t' + r.cur + '\n');
  log([new Date().toISOString(), sid, '-', String(r.cur), '-', '-', PCT + '%', 'mark-done']);
  fs.writeSync(1, String(r.cur) + '\n');
}

function hook(raw) {
  const now = new Date().toISOString();
  const p = parse(raw);
  if (!p || typeof p !== 'object') { blank(now, '-', '?/BAD_INPUT'); return; }
  const sid = clean(p.session_id, 12);
  const ev = String(p.hook_event_name || '');
  if (ev === 'Stop' || ev === 'PreToolUse') run(p, sid, now);
  else if (ev === 'PreCompact') compactGate(p, sid, now);
  else if (ev === 'SessionStart') afterCompact(p, sid, now);
  else if (ev === 'UserPromptSubmit') recognizeLong(p, sid);
}

const MODE = String(process.argv[2] || '');
const ARG_SID = process.argv[3] || process.env.CLAUDE_CODE_SESSION_ID || '';
if (MODE === '--done') {
  try { markDone(ARG_SID, process.argv[4]); process.exit(0); } catch (_) { process.stderr.write('context-gate: 没记上收尾(找不到会话号或会话记录)\n'); process.exit(1); }
}
if (MODE === '--long' || MODE === '--unlong') {
  try { (MODE === '--long' ? markLong : unmarkLong)(clean(ARG_SID, 12)); } catch (_) { /* 铁规 2 */ }
  process.exit(0);
}
if (MODE === '--is-long') {
  let yes = false;
  try { yes = isLong(clean(ARG_SID, 12)); } catch (_) { /* 铁规 2 */ }
  process.exit(yes ? 0 : 1);
}

let raw = '';
let finished = false;
const finish = () => {
  if (finished) return;
  finished = true;
  try { hook(raw); } catch (_) { /* 铁规 2 */ }
  process.exit(0);
};
process.stdin.on('data', (c) => { raw += c; });
process.stdin.on('end', finish);
process.stdin.on('error', finish);
setTimeout(finish, STDIN_TIMEOUT_MS).unref();
