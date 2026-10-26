# claude-escort · 护航模式

给 Claude Code 用的一套「撂开手也不跑偏」的干活规矩：说一句「护航 <活>」，它就按 摸底 → 登记 → 干 → 验 → 收 五步跑完，中间不来回问你，只在真该停的地方停。

*A skill + subagent set for Claude Code: say "护航 <task>" and it runs a five-step loop (survey → register → do → verify → wrap up) without asking at every step, stopping only at defined checkpoints.*

## 里面有什么

| 东西 | 在哪 | 干什么用 |
|---|---|---|
| 护航 skill | `skills/escort/SKILL.md` | 五步闭环、必停点、隐式默认记账、批量活先立标杆、报告复算、任务树 |
| 并驾细则 | `skills/escort/convoy.md` | 批量并行：拆批、心跳、进度行、子 agent 返回格式、样品闸、全力模式、模型分层、预算 |
| 验收官 | `agents/验收官.md` | 独立复核：真跑命令、贴原始输出、查越界，首行只许 PASS / FAIL / BLOCKED |
| 体验师 | `agents/体验师.md` | UI 审查：出稿前审稿（档A），落地后看真截图（档B） |
| L1 / L2 / L3 工人 | `agents/L1轻活.md` 等 | 按难度分档派活：haiku / sonnet / opus |
| 任务树 | `skills/escort/scripts/task-tree.sh` | 把 `task_plan.md` 的勾选框渲染成纯文字进度树 |
| 心跳 | `skills/escort/scripts/heartbeat.js` | 挂在子 agent 启停 hook 上，让主会话数得清「还剩几个在跑」 |
| 压缩无用上下文 | `skills/compact-context/SKILL.md` | 压缩前先把只在对话里的东西写进存档，再给你一行 `/compact` 命令；压完先读存档接着干 |
| 压完叫醒 | `skills/compact-context/scripts/wake-after-compact.sh` | 后台盯会话记录，见到压缩完成就退出、把会话叫醒，不用你再发一句「继续」 |
| 长跑 | `skills/escort/SKILL.md` 戊节 | 「护航 长跑 <活>」：上下文到线不换窗口，先收尾、再自动压缩、压完接着干，要拍板才停 |
| 上下文闸 | `skills/escort/scripts/context-gate.js` | 挂在 hook 上算上下文占了几成：到线提醒收尾；长跑会话还会拦停、守自动压缩、压完归零重算 |
| 压缩后快照 | `skills/escort/scripts/post-compact-snapshot.sh` | 压缩完把 git log、分支和改动、进度最新一条、任务树塞回上下文 |
| 闸的用例 | `skills/escort/scripts/test-context-gate.sh` | 上面两个脚本的自测，全在临时目录里跑，末行 `PASS n/n` |

## 安装

```bash
git clone https://github.com/bibi8bi/claude-escort.git
cp -r claude-escort/skills/escort ~/.claude/skills/
cp -r claude-escort/skills/compact-context ~/.claude/skills/   # 可选：压缩无用上下文
cp claude-escort/agents/*.md ~/.claude/agents/
```

新开一个 Claude Code 会话就能用。任务树要 `bash`、`git`、`awk`；心跳和上下文闸要 `node`；压完叫醒、压缩后快照要 `bash`。

## 怎么用

**护航**：`护航 把登录页的报错改成中文`。它会先看 git 状态和 `task_plan.md`，把这件活登记进去，列出要改的文件，干完按风险决定要不要派验收官，最后提交、推送、出一棵任务树。中途只在这些地方停下问你：要删测试、要动真库 / 真钱 / 真发布、要重启你在用的服务、同一道检查连续两轮没过、发现计划本身错了、要写别的仓。

**并驾**：`并驾 把这 12 个页面的标题统一成新格式`。护航的基础上，把「干」这一步拆成多个子 agent 并行，同时最多 4 个。先只做第 1 件给你看样品，你说「继续」才铺其余。

**全力**：`全力 找出所有没做权限校验的接口`。并驾再加两样：清查类的活一轮轮找到找不出新的为止；要紧结论派 3 个 agent 专门反驳。会多烧不少 token，只有你说了才开。

**任务树**：`任务树`。也可以直接跑：

```bash
bash ~/.claude/skills/escort/scripts/task-tree.sh --全
```

它读当前目录的 `task_plan.md`：顶层 `- [ ]` 是大任务，缩进的 `- [ ]` 是子任务；条目里写 `阻塞:` 算卡住，写 `〔等用户〕` / `〔等外部〕` 算在等人；写上 `YYYY-MM-DD` 登记日期就会算挂了几天。文件里写一行 `- 终点:<这个项目做完是什么样>`，会显示在树顶。加 `--base <commit>` 会把这之后翻勾的条目标上 ★。

**长跑**：`护航 长跑 把剩下的 8 个接口补上权限校验`。跟护航一样跑，只是上下文到线不换窗口：先写进度、提交，再让 Claude Code 自动压缩，压完接着干下一格，要你拍板时弹窗问。机器那一半要先挂上下面「可选：长跑 hook」；开窗前最好先敲 `/goal <什么算干完>`，细节见 `SKILL.md` 戊节。

**压缩无用上下文**：`压缩无用上下文`。觉得上下文太长、该清一清时随时说，不用等快满。它先把当前的活、做到哪、刚定的取舍、在跑的后台任务、正在查的报错、接下来要用的 skill 这六项写进一份存档，再给你一行能直接粘的 `/compact …` 命令。给命令之前它会在后台起压完叫醒脚本，你敲完 `/compact`，会话压完会自己接着干。它不提交、不写进度文件。

## 可选：心跳 hook

并驾的进度行要靠它数「还在跑几个」。不装也能用，只是进度行里那个数报不出来。在 `~/.claude/settings.json` 的 `hooks` 里加：

```json
"SubagentStart": [{"matcher": "", "hooks": [{"type": "command", "command": "node ~/.claude/skills/escort/scripts/heartbeat.js SubagentStart", "timeout": 5}]}],
"SubagentStop":  [{"matcher": "", "hooks": [{"type": "command", "command": "node ~/.claude/skills/escort/scripts/heartbeat.js SubagentStop", "timeout": 5}]}]
```

日志写到 `~/.claude/escort-heartbeat.log`，想换位置就设环境变量 `ESCORT_HEARTBEAT_LOG`。超过 2MB 自动截到最后 500 行。

## 可选：长跑 hook

长跑和上下文提醒要靠 `context-gate.js` 和 `post-compact-snapshot.sh` 挂在 hook 上。不装也能用护航，只是没人替你盯上下文。在 `~/.claude/settings.json` 的 `hooks` 里加这五个挂点（SessionStart 那个挂两条）：

```json
"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "node ~/.claude/skills/escort/scripts/context-gate.js", "timeout": 5}]}],
"PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "node ~/.claude/skills/escort/scripts/context-gate.js", "timeout": 5}]}],
"PreCompact": [{"matcher": "auto", "hooks": [{"type": "command", "command": "node ~/.claude/skills/escort/scripts/context-gate.js", "timeout": 5}]}],
"SessionStart": [{"matcher": "compact", "hooks": [
  {"type": "command", "command": "node ~/.claude/skills/escort/scripts/context-gate.js", "timeout": 5},
  {"type": "command", "command": "bash ~/.claude/skills/escort/scripts/post-compact-snapshot.sh", "timeout": 10}
]}],
"UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "node ~/.claude/skills/escort/scripts/context-gate.js", "timeout": 5}]}]
```

- **五个都别加 `"async": true`**。Stop、PreToolUse、PreCompact 设了 async 就回不了「拦下 / 注入」，闸等于没装；SessionStart 设了，压缩后快照可能进不了上下文；UserPromptSubmit 设了，长跑标记可能比第一次 Stop 还晚记上。
- **已经有同名挂点的，把上面那一项追加进原来的数组，别整段覆盖**，不然你原来的 hook 就没了。比如原来已有 `"Stop": [A]`，改成 `"Stop": [A, 上面那项]`。
- 五个挂点是同一行命令，脚本自己看事件名分路。

挂完自查（读配置目录下的 `settings.json`：设了 `CLAUDE_CONFIG_DIR` 就读那里，没设读 `~/.claude/`）。每个挂点逐条看：命令里有没有那个脚本名、有没有设 `async`（设了就不能拦）、matcher 对不对（PreToolUse 要空或 `*`，PreCompact 要 `auto`，SessionStart 要 `compact`）。每行该是 `ok`，有一行 `错` 就照冒号后面那句改；读不到文件只打一行「缺 settings.json」：

```bash
node -e '
const fs = require("fs"), path = require("path"), os = require("os");
const f = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude"), "settings.json");
let h;
try { h = JSON.parse(fs.readFileSync(f, "utf8")).hooks || {}; } catch (_) { console.log("缺 settings.json(" + f + " 读不到或不是合法 JSON)"); process.exit(1); }
const want = [["Stop", "context-gate.js"], ["PreToolUse", "context-gate.js", ["", "*"]], ["PreCompact", "context-gate.js", ["auto"]],
  ["SessionStart", "context-gate.js", ["compact"]], ["SessionStart", "post-compact-snapshot.sh", ["compact"]], ["UserPromptSubmit", "context-gate.js"]];
let bad = 0;
for (const [e, s, m] of want) {
  const hits = [];
  for (const g of h[e] || []) for (const k of (g && g.hooks) || []) if (String(k.command || "").includes(s)) hits.push([g, k]);
  const good = hits.find(([g, k]) => k.async !== true && (!m || m.includes(g.matcher == null ? "" : g.matcher)));
  let why = "";
  if (!hits.length) why = "没挂";
  else if (!good) why = hits[0][1].async === true ? "设了 async,要去掉" : "matcher 是 " + JSON.stringify(hits[0][0].matcher) + ",要 " + m.map((x) => JSON.stringify(x)).join(" 或 ");
  console.log((why ? "错  " : "ok  ") + e + " " + s + (why ? ":" + why : ""));
  if (why) bad = 1;
}
process.exit(bad);'
```

再跑一遍用例确认脚本在你机器上能跑：`bash ~/.claude/skills/escort/scripts/test-context-gate.sh`，末行 `PASS n/n` 就对了。

**环境变量**（全可不设，完整清单在 `context-gate.js` 头注释）：

- `ESCORT_CONTEXT_WINDOW`：窗口大小。用 100 万窗口的模型请设 `1000000`，不设的话没用到 20 万之前都按 20 万算，会提前提醒。最稳的设法是加在五条命令前面，例如 `"command": "ESCORT_CONTEXT_WINDOW=1000000 node ~/.claude/skills/escort/scripts/context-gate.js"`。
- `ESCORT_GATE_PCT`：线，占窗口的百分数，默认 60。
- `ESCORT_DATA_DIR`：数据文件放哪，默认 `<配置目录>/escort/`（配置目录 = `CLAUDE_CONFIG_DIR`，没设就是 `~/.claude`；里面是提醒记录、收尾记录、长跑名单、日志 `gate.log`）。
- `ESCORT_GATE_GRACE` / `ESCORT_GATE_LONG_GRACE`：收尾之后再涨多少 token 以内不再催，默认窗口的 5% / 10%（20 万窗口 = 1 万 / 2 万）；写了绝对值就用绝对值。
- `ESCORT_GATE_COMPACT_STALE`：长跑会话收尾之后涨多少以内算「收尾新鲜」、放行自动压缩，默认窗口的 10%；写了绝对值就用绝对值。
- `ESCORT_GATE_PASS_AT`：占用超过这个 token 数，自动压缩一律放行。默认 `min(窗口 × 0.9, 窗口 − 45000)`：按 Claude Code 2.1.310，自动压缩点约是窗口 − 33000，再大到窗口 − 23000 请求就直接失败，放行线得比自动压缩点低。20 万窗口这条线是 15.5 万，自动压缩一来多半已过线，守门基本只在大窗口里起作用。换了 Claude Code 版本这几个数可能变。

**`autoCompactWindow`**：这是 Claude Code 自己的设置键，管「上下文涨到多少 token 自动压缩」。本套件不替你设，也不依赖某个具体值。长跑的节奏是：到线（`ESCORT_GATE_PCT`）先收尾，收完之后自动压缩才放行，所以闸的线要比自动压缩的触发点低一截，给收尾留出余量。**20 万窗口的人别照抄 100 万窗口的数**（比如一个大于 20 万的数）：那个数比你整个窗口还大，自动压缩的触发点就跟你的线对不上了。它是全局键，改了所有会话都吃；闸只在长跑会话里挡压缩，别的会话照常压。

## 可选：自己接的部分

规则里有几处是「机器判」的：验收报告的判据复跑、改动范围对盘、子 agent 用量账单。这一版只给了规则和手工做法（命令都写在文档里），没带自动化脚本。想接的话，照文档里写的判法自己写 hook 或脚本就行。上下文占比闸已经带了脚本，见上面「可选：长跑 hook」。

## 配置

- 项目里有术语表的，派子 agent 时在任务书开头写一行「开工前先读 <术语表路径>」（`SKILL.md`「可派的护航 agent」那段的第三条纪律）。
- L1 / L2 的 `effort`、`maxTurns` 写在 agent 定义文件的 frontmatter 里，按需要改。
- 任务树默认读项目根目录的 `task_plan.md`，没有就找 `planning/task_plan.md`，也可以用 `--plan <路径>` 指定。

## 许可证

MIT，见 [LICENSE](LICENSE)。
