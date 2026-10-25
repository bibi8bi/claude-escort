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

## 安装

```bash
git clone https://github.com/bibi8bi/claude-escort.git
cp -r claude-escort/skills/escort ~/.claude/skills/
cp -r claude-escort/skills/compact-context ~/.claude/skills/   # 可选：压缩无用上下文
cp claude-escort/agents/*.md ~/.claude/agents/
```

新开一个 Claude Code 会话就能用。任务树要 `bash`、`git`、`awk`；心跳要 `node`；压完叫醒要 `bash`。

## 怎么用

**护航**：`护航 把登录页的报错改成中文`。它会先看 git 状态和 `task_plan.md`，把这件活登记进去，列出要改的文件，干完按风险决定要不要派验收官，最后提交、推送、出一棵任务树。中途只在这些地方停下问你：要删测试、要动真库 / 真钱 / 真发布、要重启你在用的服务、同一道检查连续两轮没过、发现计划本身错了、要写别的仓。

**并驾**：`并驾 把这 12 个页面的标题统一成新格式`。护航的基础上，把「干」这一步拆成多个子 agent 并行，同时最多 4 个。先只做第 1 件给你看样品，你说「继续」才铺其余。

**全力**：`全力 找出所有没做权限校验的接口`。并驾再加两样：清查类的活一轮轮找到找不出新的为止；要紧结论派 3 个 agent 专门反驳。会多烧不少 token，只有你说了才开。

**任务树**：`任务树`。也可以直接跑：

```bash
bash ~/.claude/skills/escort/scripts/task-tree.sh --全
```

它读当前目录的 `task_plan.md`：顶层 `- [ ]` 是大任务，缩进的 `- [ ]` 是子任务；条目里写 `阻塞:` 算卡住，写 `〔等用户〕` / `〔等外部〕` 算在等人；写上 `YYYY-MM-DD` 登记日期就会算挂了几天。文件里写一行 `- 终点:<这个项目做完是什么样>`，会显示在树顶。加 `--base <commit>` 会把这之后翻勾的条目标上 ★。

**压缩无用上下文**：`压缩无用上下文`。觉得上下文太长、该清一清时随时说，不用等快满。它先把当前的活、做到哪、刚定的取舍、在跑的后台任务、正在查的报错、接下来要用的 skill 这六项写进一份存档，再给你一行能直接粘的 `/compact …` 命令。给命令之前它会在后台起压完叫醒脚本，你敲完 `/compact`，会话压完会自己接着干。它不提交、不写进度文件。

## 可选：心跳 hook

并驾的进度行要靠它数「还在跑几个」。不装也能用，只是进度行里那个数报不出来。在 `~/.claude/settings.json` 的 `hooks` 里加：

```json
"SubagentStart": [{"matcher": "", "hooks": [{"type": "command", "command": "node ~/.claude/skills/escort/scripts/heartbeat.js SubagentStart", "timeout": 5}]}],
"SubagentStop":  [{"matcher": "", "hooks": [{"type": "command", "command": "node ~/.claude/skills/escort/scripts/heartbeat.js SubagentStop", "timeout": 5}]}]
```

日志写到 `~/.claude/escort-heartbeat.log`，想换位置就设环境变量 `ESCORT_HEARTBEAT_LOG`。超过 2MB 自动截到最后 500 行。

## 可选：自己接的部分

规则里有几处是「机器判」的：验收报告的判据复跑、改动范围对盘、子 agent 用量账单、上下文占比闸。这一版只给了规则和手工做法（命令都写在文档里），没带自动化脚本。想接的话，照文档里写的判法自己写 hook 或脚本就行。

## 配置

- 项目里有术语表的，派子 agent 时在任务书开头写一行「开工前先读 <术语表路径>」（`SKILL.md`「可派的护航 agent」那段的第三条纪律）。
- L1 / L2 的 `effort`、`maxTurns` 写在 agent 定义文件的 frontmatter 里，按需要改。
- 任务树默认读项目根目录的 `task_plan.md`，没有就找 `planning/task_plan.md`，也可以用 `--plan <路径>` 指定。

## 许可证

MIT，见 [LICENSE](LICENSE)。
