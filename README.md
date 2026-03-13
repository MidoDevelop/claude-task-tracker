# Claude Task Tracker

[English](#english) | [中文](#中文)

---

## English

A 6-dimension task snapshot system for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Automatically captures task context when a session ends and restores it when the next session starts — so you never lose track of where you left off.

### How It Works

```
Session ends → Stop hook captures snapshot → Next session starts → SessionStart hook injects summary
```

When Claude Code stops, the Stop hook extracts 6 dimensions of context from the session:

| # | Dimension | Source |
|---|-----------|--------|
| 1 | **Task Goal** | First user message |
| 2 | **Progress** | `<!-- TASK_STATUS -->` block in last AI response |
| 3 | **Errors** | Tool results containing error keywords |
| 4 | **Modified Files** | `git diff` (staged + unstaged + untracked) |
| 5 | **Decisions** | TASK_STATUS block + text pattern matching |
| 6 | **User Directives** | Recent user messages |

On next session start, the snapshot is injected as context so Claude can pick up where it left off.

### Installation

**One-line install:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MidoDevelop/claude-task-tracker/main/install.sh)
```

**Or clone & install:**

```bash
git clone https://github.com/MidoDevelop/claude-task-tracker.git
bash claude-task-tracker/install.sh
```

The installer will:
1. Create hook scripts in `~/.claude/tools/task-tracker/`
2. Register Stop and SessionStart hooks in `~/.claude/settings.json`
3. Add the `TASK_STATUS` format guide to `~/.claude/CLAUDE.md`
4. Create a snapshot directory at `~/.claude/task-snapshots/`

### Optional: Auto-Resume Wrapper

Add an alias so Claude automatically prompts you to resume unfinished tasks:

```bash
echo 'alias claude="bash ~/.claude/tools/task-tracker/claude-wrapper.sh"' >> ~/.zshrc
source ~/.zshrc
```

### Snapshot Format (v3)

Snapshots are stored as JSON in `~/.claude/task-snapshots/`:

```json
{
  "version": 3,
  "timestamp": "2026-03-13T07:47:43Z",
  "session_id": "...",
  "cwd": "/path/to/project",
  "project": "project-name",
  "goal": "user's first message",
  "progress": {
    "goal": "one-line summary",
    "done": ["completed item 1", "completed item 2"],
    "todo": ["pending item 1"]
  },
  "errors": ["error message ..."],
  "modified_files": ["M\tfile.py", "?\tnew-file.sh"],
  "decisions": ["chose X because Y"],
  "user_directives": ["user instruction ..."]
}
```

- Snapshots expire after **7 days**
- One snapshot per project directory (keyed by path hash)

### TASK_STATUS Block

For best results, Claude should include a `TASK_STATUS` comment at the end of responses:

```html
<!-- TASK_STATUS
goal: what we're doing
done: ["step 1", "step 2"]
todo: ["step 3"]
decisions: ["chose X because Y"]
-->
```

The installer automatically adds this instruction to `~/.claude/CLAUDE.md`.

### Uninstall

```bash
bash ~/.claude/tools/task-tracker/uninstall.sh
```

### Requirements

- Claude Code CLI
- Python 3.6+
- Git (for modified files detection)
- Bash

---

## 中文

一个面向 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 的 6 维度任务快照系统。在会话结束时自动捕获任务上下文，在下次会话启动时自动恢复——让你永远不会丢失工作进度。

### 工作原理

```
会话结束 → Stop Hook 捕获快照 → 下次会话启动 → SessionStart Hook 注入摘要
```

当 Claude Code 停止时，Stop Hook 从会话中提取 6 个维度的上下文：

| # | 维度 | 来源 |
|---|------|------|
| 1 | **任务目标** | 用户第一条消息 |
| 2 | **进度** | AI 最后回复中的 `<!-- TASK_STATUS -->` 块 |
| 3 | **错误信息** | 包含错误关键词的工具执行结果 |
| 4 | **修改的文件** | `git diff`（已暂存 + 未暂存 + 未跟踪） |
| 5 | **关键决策** | TASK_STATUS 块 + 文本模式匹配 |
| 6 | **用户指令** | 最近的用户消息 |

下次会话启动时，快照作为上下文注入，让 Claude 从上次中断的地方继续。

### 安装

**一行命令安装：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MidoDevelop/claude-task-tracker/main/install.sh)
```

**或克隆后安装：**

```bash
git clone https://github.com/MidoDevelop/claude-task-tracker.git
bash claude-task-tracker/install.sh
```

安装器会自动：
1. 在 `~/.claude/tools/task-tracker/` 创建 Hook 脚本
2. 在 `~/.claude/settings.json` 中注册 Stop 和 SessionStart Hooks
3. 在 `~/.claude/CLAUDE.md` 中添加 `TASK_STATUS` 格式说明
4. 创建快照目录 `~/.claude/task-snapshots/`

### 可选：自动恢复包装器

添加 alias，让 Claude 启动时自动提示恢复未完成的任务：

```bash
echo 'alias claude="bash ~/.claude/tools/task-tracker/claude-wrapper.sh"' >> ~/.zshrc
source ~/.zshrc
```

### 快照格式（v3）

快照以 JSON 格式存储在 `~/.claude/task-snapshots/`：

```json
{
  "version": 3,
  "timestamp": "2026-03-13T07:47:43Z",
  "session_id": "...",
  "cwd": "/path/to/project",
  "project": "项目名",
  "goal": "用户的第一条消息",
  "progress": {
    "goal": "一句话概括",
    "done": ["已完成项1", "已完成项2"],
    "todo": ["待完成项1"]
  },
  "errors": ["错误信息..."],
  "modified_files": ["M\tfile.py", "?\tnew-file.sh"],
  "decisions": ["选择X因为Y"],
  "user_directives": ["用户指令..."]
}
```

- 快照 **7 天**后自动过期
- 每个项目目录一个快照（按路径哈希区分）

### TASK_STATUS 块

为了最佳效果，Claude 应在每次回复末尾附带 `TASK_STATUS` 注释：

```html
<!-- TASK_STATUS
goal: 当前任务目标
done: ["步骤1", "步骤2"]
todo: ["步骤3"]
decisions: ["选择X因为Y"]
-->
```

安装器会自动将此指令添加到 `~/.claude/CLAUDE.md`。

### 卸载

```bash
bash ~/.claude/tools/task-tracker/uninstall.sh
```

### 依赖

- Claude Code CLI
- Python 3.6+
- Git（用于检测文件变更）
- Bash

---

## License

MIT
