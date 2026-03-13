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
