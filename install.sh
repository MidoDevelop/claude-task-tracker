#!/usr/bin/env bash
# ============================================================
# claude-task-tracker v3 installer (self-contained)
#
# Install:
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/claude-task-tracker/main/install.sh)
#
# Or clone & install:
#   git clone https://github.com/USER/claude-task-tracker.git
#   bash claude-task-tracker/install.sh
# ============================================================

set -euo pipefail

TOOL_DIR="$HOME/.claude/tools/task-tracker"
SNAPSHOT_DIR="$HOME/.claude/task-snapshots"
SETTINGS_FILE="$HOME/.claude/settings.json"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"

# --- Portable python detection ---
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
if [ -z "$PYTHON" ]; then
    echo "ERROR: Python not found. Please install Python 3.6+."
    exit 1
fi

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   Claude Task Tracker v3 Installer   ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
echo "  Python: $PYTHON"
echo ""

# --- 1. Create directories ---
mkdir -p "$TOOL_DIR" "$SNAPSHOT_DIR"

# --- 2. Generate on-stop.sh ---
cat > "$TOOL_DIR/on-stop.sh" << 'HOOK_STOP'
#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT_DIR="$HOME/.claude/task-snapshots"
mkdir -p "$SNAPSHOT_DIR"

INPUT=$(cat)

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
if [ -z "$PYTHON" ]; then exit 0; fi

export TASK_TRACKER_INPUT="$INPUT"
export TASK_TRACKER_SNAPSHOT_DIR="$SNAPSHOT_DIR"

"$PYTHON" << 'PYSCRIPT'
import os, json, hashlib, sys, re, subprocess
from datetime import datetime, timezone

raw = os.environ.get("TASK_TRACKER_INPUT", "")
snapshot_dir = os.environ.get("TASK_TRACKER_SNAPSHOT_DIR", "")

if not raw or not snapshot_dir:
    sys.exit(0)

try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)

if d.get("stop_hook_active"):
    sys.exit(0)

cwd = d.get("cwd", "")
session_id = d.get("session_id", "")
last_msg = d.get("last_assistant_message", "")
transcript_path = d.get("transcript_path", "")

if not last_msg or not cwd:
    sys.exit(0)

# ============================================================
# 1. GOAL: Extract from initial user request
# ============================================================
first_user_message = ""
user_directives = []
errors = []

if transcript_path and os.path.exists(transcript_path):
    try:
        user_msg_count = 0
        with open(transcript_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except Exception:
                    continue
                role = msg.get("role", "")

                # --- Extract user messages ---
                if role == "user":
                    user_msg_count += 1
                    content = msg.get("content", "")
                    if isinstance(content, list):
                        parts = []
                        for b in content:
                            if isinstance(b, dict) and b.get("type") == "text":
                                parts.append(b.get("text", ""))
                            elif isinstance(b, str):
                                parts.append(b)
                        content = "\n".join(parts)
                    content = str(content).strip()

                    # First user message = goal
                    if user_msg_count == 1:
                        first_user_message = content[:500]

                    # 7. USER DIRECTIVES: messages that look like instructions
                    if len(content) > 10 and user_msg_count > 1:
                        user_directives.append(content[:300])
                        if len(user_directives) > 5:
                            user_directives.pop(0)

                # --- 3. ERRORS: Extract from tool results ---
                elif role == "result" or role == "tool":
                    content = msg.get("content", "")
                    if isinstance(content, list):
                        parts = []
                        for b in content:
                            if isinstance(b, dict) and b.get("type") == "text":
                                parts.append(b.get("text", ""))
                            elif isinstance(b, str):
                                parts.append(b)
                        content = "\n".join(parts)
                    content = str(content)
                    if any(kw in content.lower() for kw in [
                        "error", "failed", "exception", "traceback",
                        "fatal", "panic", "denied", "not found",
                        "command failed", "exit code"
                    ]):
                        err_text = content[:500]
                        if len(content) > 500:
                            err_text += "..."
                        errors.append(err_text)
                        if len(errors) > 5:
                            errors.pop(0)
    except Exception:
        pass

# ============================================================
# 2. PROGRESS: Parse <!-- TASK_STATUS --> from last AI message
# ============================================================
progress = {}
decisions = []

status_match = re.search(r'<!--\s*TASK_STATUS\s*\n(.*?)-->', last_msg, re.DOTALL)
if status_match:
    block = status_match.group(1).strip()
    for line in block.split("\n"):
        line = line.strip()
        if not line:
            continue
        m = re.match(r'^(\w+)\s*:\s*(.+)$', line)
        if m:
            key = m.group(1).lower()
            val = m.group(2).strip()
            if val.startswith("["):
                try:
                    val = json.loads(val)
                except Exception:
                    pass
            if key in ("done", "todo", "goal"):
                progress[key] = val
            elif key == "decisions":
                if isinstance(val, list):
                    decisions = val
                else:
                    decisions = [val]

# ============================================================
# 4. MODIFIED FILES: From git diff
# ============================================================
modified_files = []
try:
    result = subprocess.run(
        ["git", "diff", "--name-status", "HEAD"],
        capture_output=True, text=True, cwd=cwd, timeout=5
    )
    if result.returncode == 0 and result.stdout.strip():
        for line in result.stdout.strip().split("\n"):
            if line.strip():
                modified_files.append(line.strip())

    result2 = subprocess.run(
        ["git", "diff", "--name-status", "--cached"],
        capture_output=True, text=True, cwd=cwd, timeout=5
    )
    if result2.returncode == 0 and result2.stdout.strip():
        for line in result2.stdout.strip().split("\n"):
            line = line.strip()
            if line and line not in modified_files:
                modified_files.append(line)

    result3 = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard"],
        capture_output=True, text=True, cwd=cwd, timeout=5
    )
    if result3.returncode == 0 and result3.stdout.strip():
        for line in result3.stdout.strip().split("\n"):
            line = line.strip()
            if line:
                entry = f"?\t{line}"
                if entry not in modified_files:
                    modified_files.append(entry)
except Exception:
    pass

modified_files = modified_files[:30]

# ============================================================
# 5. DECISIONS: Also scan last assistant message for patterns
# ============================================================
if not decisions:
    decision_patterns = [
        r'(?:选择|chose|选了|采用|decided)[^。.！!\n]{5,80}(?:因为|because|由于|原因)[^。.！!\n]{5,80}[。.！!]?',
        r'(?:放弃|rejected|弃用|不用)[^。.！!\n]{5,80}(?:因为|because|由于|原因)[^。.！!\n]{5,80}[。.！!]?',
        r'(?:试了|tried|尝试)[^。.！!\n]{5,80}(?:但|but|however)[^。.！!\n]{5,80}[。.！!]?',
        r'(?:改为|switched to|改用|换成)[^。.！!\n]{5,80}[。.！!]?',
    ]
    for pat in decision_patterns:
        for m in re.finditer(pat, last_msg):
            decisions.append(m.group(0).strip())
            if len(decisions) >= 5:
                break
        if len(decisions) >= 5:
            break

# ============================================================
# Build snapshot v3
# ============================================================
project_hash = hashlib.md5(cwd.encode()).hexdigest()[:12]
project_name = os.path.basename(cwd) or "root"
snapshot_path = os.path.join(snapshot_dir, f"{project_name}_{project_hash}.json")

snapshot = {
    "version": 3,
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "session_id": session_id,
    "cwd": cwd,
    "project": project_name,
    "goal": first_user_message,
    "progress": progress if progress else None,
    "errors": errors if errors else None,
    "modified_files": modified_files if modified_files else None,
    "decisions": decisions if decisions else None,
    "user_directives": user_directives if user_directives else None,
}

snapshot = {k: v for k, v in snapshot.items() if v is not None}

with open(snapshot_path, "w", encoding="utf-8") as f:
    json.dump(snapshot, f, ensure_ascii=False, indent=2)
PYSCRIPT
HOOK_STOP

# --- 3. Generate on-session-start.sh ---
cat > "$TOOL_DIR/on-session-start.sh" << 'HOOK_START'
#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT_DIR="$HOME/.claude/task-snapshots"
INPUT=$(cat)

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
if [ -z "$PYTHON" ]; then exit 0; fi

export TASK_TRACKER_INPUT="$INPUT"
export TASK_TRACKER_SNAPSHOT_DIR="$SNAPSHOT_DIR"

"$PYTHON" << 'PYSCRIPT'
import os, json, hashlib, sys
from datetime import datetime, timezone

raw = os.environ.get("TASK_TRACKER_INPUT", "")
snapshot_dir = os.environ.get("TASK_TRACKER_SNAPSHOT_DIR", "")

if not raw or not snapshot_dir:
    sys.exit(0)

try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)

cwd = d.get("cwd", "")
if not cwd:
    sys.exit(0)

project_hash = hashlib.md5(cwd.encode()).hexdigest()[:12]
project_name = os.path.basename(cwd) or "root"
snapshot_path = os.path.join(snapshot_dir, f"{project_name}_{project_hash}.json")

if not os.path.exists(snapshot_path):
    sys.exit(0)

mtime = os.path.getmtime(snapshot_path)
age_seconds = datetime.now(timezone.utc).timestamp() - mtime
age_days = age_seconds / 86400
if age_days > 7:
    sys.exit(0)

with open(snapshot_path, "r", encoding="utf-8") as f:
    snapshot = json.load(f)

# --- Age description ---
if age_days >= 1:
    age_str = f"{age_days:.1f} 天前"
elif age_seconds >= 3600:
    age_str = f"{age_seconds / 3600:.0f} 小时前"
else:
    age_str = f"{max(1, age_seconds / 60):.0f} 分钟前"

# --- Build structured summary ---
goal = snapshot.get("goal", "（未捕获）")
progress = snapshot.get("progress", {})
errors = snapshot.get("errors", [])
modified_files = snapshot.get("modified_files", [])
decisions = snapshot.get("decisions", [])
user_directives = snapshot.get("user_directives", [])

sections = []

# Goal
sections.append(f"任务目标：{goal}")

# Progress
if progress:
    done = progress.get("done", [])
    todo = progress.get("todo", [])
    if isinstance(done, list):
        done = "、".join(done)
    if isinstance(todo, list):
        todo = "、".join(todo)
    if done:
        sections.append(f"已完成：{done}")
    if todo:
        sections.append(f"待完成：{todo}")

# Modified files
if modified_files:
    files_str = "\n".join(f"  {f}" for f in modified_files[:15])
    if len(modified_files) > 15:
        files_str += f"\n  ...（共 {len(modified_files)} 个文件）"
    sections.append(f"已修改文件：\n{files_str}")

# Errors
if errors:
    err_items = "\n".join(f"  - {e[:200]}" for e in errors[-3:])
    sections.append(f"最近错误：\n{err_items}")

# Decisions
if decisions:
    dec_items = "\n".join(f"  - {d}" for d in decisions[-3:])
    sections.append(f"关键决策：\n{dec_items}")

# User directives
if user_directives:
    dir_items = "\n".join(f"  - {d[:150]}" for d in user_directives[-3:])
    sections.append(f"用户指令：\n{dir_items}")

body = "\n".join(sections)

print(f"""[TASK_SNAPSHOT]
检测到上次会话快照（v3），请在首次回复时向用户展示以下摘要：

快照文件：{snapshot_path}
项目：{cwd}
时间：{snapshot.get("timestamp", "")}（{age_str}）

{body}

**必须执行**：在首次回复开头，用简短格式向用户展示快照摘要，然后提示用户可以说「继续」恢复或直接开始新话题。
如果用户说「继续」或表示要恢复上次任务，直接基于快照上下文继续工作。
如果用户说「重新开始」或开始新话题，先删除快照文件 "{snapshot_path}"，然后开始新对话。
如果用户直接提出新问题，视为开始新对话。
""")
PYSCRIPT
HOOK_START

chmod +x "$TOOL_DIR/on-stop.sh" "$TOOL_DIR/on-session-start.sh"
echo "  [1/4] Hook scripts created."

# --- 4. Generate claude-wrapper.sh ---
cat > "$TOOL_DIR/claude-wrapper.sh" << 'WRAPPER'
#!/usr/bin/env bash
# Claude Code wrapper: 检测到未完成任务快照时自动发送恢复消息
# 用法：用 alias 替代 claude 命令，或直接 source 此脚本

claude_wrapper() {
  local snapshot_dir="$HOME/.claude/task-snapshots"
  local real_claude
  real_claude=$(command -v claude 2>/dev/null || echo "/usr/local/bin/claude")

  # 如果用户传了参数（prompt 或 flags），直接透传
  if [ $# -gt 0 ]; then
    "$real_claude" "$@"
    return
  fi

  # 无参数启动时，检查当前目录是否有快照
  local cwd="$PWD"
  local project_hash
  project_hash=$(printf '%s' "$cwd" | md5 -q 2>/dev/null || printf '%s' "$cwd" | md5sum | cut -c1-32)
  project_hash="${project_hash:0:12}"
  local project_name
  project_name=$(basename "$cwd")
  local snapshot_path="$snapshot_dir/${project_name}_${project_hash}.json"

  if [ -f "$snapshot_path" ]; then
    # 检查快照是否超过 7 天
    local now
    now=$(date +%s)
    local mtime
    mtime=$(stat -f %m "$snapshot_path" 2>/dev/null || stat -c %Y "$snapshot_path" 2>/dev/null || echo 0)
    local age_days=$(( (now - mtime) / 86400 ))

    if [ "$age_days" -lt 7 ]; then
      "$real_claude" "检查上次未完成任务"
      return
    fi
  fi

  # 没有快照或已过期，正常启动
  "$real_claude"
}

# 如果直接执行此脚本（非 source），运行 wrapper
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  claude_wrapper "$@"
fi
WRAPPER
chmod +x "$TOOL_DIR/claude-wrapper.sh"
echo "  [2/4] Wrapper script created."

# --- 5. Update settings.json ---
"$PYTHON" - "$SETTINGS_FILE" "$TOOL_DIR" << 'PYSETUP'
import json, os, sys

settings_file = sys.argv[1]
tool_dir = sys.argv[2]

if os.path.exists(settings_file):
    with open(settings_file, "r") as f:
        settings = json.load(f)
else:
    settings = {}

hooks = settings.get("hooks", {})

stop_hook = {
    "matcher": "",
    "hooks": [{"type": "command", "command": f"/bin/bash {tool_dir}/on-stop.sh"}]
}
start_hook = {
    "matcher": "",
    "hooks": [{"type": "command", "command": f"/bin/bash {tool_dir}/on-session-start.sh"}]
}

MARKER = f"{tool_dir}/"

# Replace existing or add new
stop_list = hooks.get("Stop", [])
stop_list = [h for h in stop_list if MARKER not in json.dumps(h)]
stop_list.append(stop_hook)
hooks["Stop"] = stop_list

start_list = hooks.get("SessionStart", [])
start_list = [h for h in start_list if MARKER not in json.dumps(h)]
start_list.append(start_hook)
hooks["SessionStart"] = start_list

settings["hooks"] = hooks

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
PYSETUP
echo "  [3/4] Hooks registered in settings.json."

# --- 6. Add/update TASK_STATUS instruction in CLAUDE.md ---
TASK_STATUS_SECTION="## Task Status Tracking"

# Create CLAUDE.md if it doesn't exist
touch "$CLAUDE_MD"

# Remove old task-tracker section if present, then append new one
"$PYTHON" - "$CLAUDE_MD" << 'PYUPDATE'
import sys, re

claude_md = sys.argv[1]

with open(claude_md, "r", encoding="utf-8") as f:
    content = f.read()

# Remove old section (## Task Status Tracking ... until next ## or end of file)
pattern = r'\n*## Task Status Tracking[^\n]*\n.*?(?=\n## |\Z)'
content = re.sub(pattern, '', content, flags=re.DOTALL)
content = content.rstrip()

# Append new section
new_section = """

## Task Status Tracking / 任务状态追踪（task-tracker v3）

每次回复的末尾，尽量附带一个 HTML 注释块来记录当前任务状态。格式如下：

```
<!-- TASK_STATUS
goal: 一句话描述当前任务目标
done: ["已完成项1", "已完成项2"]
todo: ["待完成项1", "待完成项2"]
decisions: ["选择X因为Y", "放弃Z因为W"]
-->
```

规则：
- **尽量每次回复都附带**，尤其是涉及多步骤任务时
- 用户看不到 HTML 注释，不影响阅读体验
- goal 用一句话概括，done/todo/decisions 用 JSON 数组
- decisions 记录关键决策（选了什么、弃了什么、为什么）
- 如果是简单问答（非任务性对话），可以省略
- Stop Hook 会自动提取此块 + git 变更 + 错误信息 + 用户指令，组成 6 维快照
"""

content += new_section

with open(claude_md, "w", encoding="utf-8") as f:
    f.write(content)
PYUPDATE
echo "  [4/4] CLAUDE.md updated with v3 TASK_STATUS format."

# --- 7. Generate uninstall.sh ---
cat > "$TOOL_DIR/uninstall.sh" << 'UNINSTALL'
#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="$HOME/.claude/tools/task-tracker"
SETTINGS_FILE="$HOME/.claude/settings.json"

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
if [ -z "$PYTHON" ]; then echo "ERROR: Python not found."; exit 1; fi

echo ""
echo "  Uninstalling Claude Task Tracker v3..."
echo ""

# Remove hooks from settings.json
"$PYTHON" - "$SETTINGS_FILE" "$TOOL_DIR" << 'PYSETUP'
import json, os, sys

settings_file = sys.argv[1]
tool_dir = sys.argv[2]

if not os.path.exists(settings_file):
    print("  No settings file found.")
    sys.exit(0)

with open(settings_file, "r") as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
changed = False
for event in ["Stop", "SessionStart"]:
    if event in hooks:
        original = hooks[event]
        hooks[event] = [h for h in original if tool_dir not in json.dumps(h)]
        if len(hooks[event]) != len(original):
            changed = True
        if not hooks[event]:
            del hooks[event]

if not hooks:
    settings.pop("hooks", None)
else:
    settings["hooks"] = hooks

if changed:
    with open(settings_file, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
    print("  Hooks removed from settings.json.")
else:
    print("  No hooks found to remove.")
PYSETUP

echo ""
read -p "  Delete snapshot history? (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$HOME/.claude/task-snapshots"
    echo "  Snapshots deleted."
fi

read -p "  Delete tool files? (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$TOOL_DIR"
    echo "  Tool files deleted."
fi

echo ""
echo "  NOTE: The TASK_STATUS block in CLAUDE.md was not removed."
echo "  You can manually remove the '## Task Status Tracking' section if desired."
echo ""
echo "  Uninstall complete."
UNINSTALL
chmod +x "$TOOL_DIR/uninstall.sh"

echo ""
echo "  ════════════════════════════════════════"
echo "  Installed successfully! (v3)"
echo ""
echo "  Files:"
echo "    $TOOL_DIR/on-stop.sh          (Stop hook: 6-dim snapshot)"
echo "    $TOOL_DIR/on-session-start.sh  (SessionStart hook: show summary)"
echo "    $TOOL_DIR/claude-wrapper.sh    (Optional: auto-resume wrapper)"
echo "    $TOOL_DIR/uninstall.sh"
echo "    $SNAPSHOT_DIR/"
echo ""
echo "  6 dimensions captured automatically:"
echo "    1. Task goal        ← first user message"
echo "    2. Progress         ← AI's TASK_STATUS block (best-effort)"
echo "    3. Errors           ← tool result errors"
echo "    4. Modified files   ← git diff"
echo "    5. Decisions        ← TASK_STATUS + text patterns"
echo "    6. User directives  ← recent user messages"
echo ""
echo "  Optional: add wrapper alias to your shell rc:"
echo "    echo 'alias claude=\"bash $TOOL_DIR/claude-wrapper.sh\"' >> ~/.zshrc"
echo ""
echo "  Uninstall:"
echo "    bash $TOOL_DIR/uninstall.sh"
echo ""
