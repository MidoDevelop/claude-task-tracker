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
                    # Skip very short or question-only messages
                    if len(content) > 10 and user_msg_count > 1:
                        # Keep last 5 user messages as potential directives
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
                    # Look for error indicators
                    if any(kw in content.lower() for kw in [
                        "error", "failed", "exception", "traceback",
                        "fatal", "panic", "denied", "not found",
                        "command failed", "exit code"
                    ]):
                        # Truncate long errors
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
# 4. MODIFIED FILES: From git diff --stat
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

    # Also check staged changes
    result2 = subprocess.run(
        ["git", "diff", "--name-status", "--cached"],
        capture_output=True, text=True, cwd=cwd, timeout=5
    )
    if result2.returncode == 0 and result2.stdout.strip():
        for line in result2.stdout.strip().split("\n"):
            line = line.strip()
            if line and line not in modified_files:
                modified_files.append(line)

    # Also check untracked files
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

# Limit
modified_files = modified_files[:30]

# ============================================================
# 5. DECISIONS: Also scan last assistant message for decision patterns
# ============================================================
if not decisions:
    # Look for decision patterns in Chinese and English
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

    # Dimension 1: Goal
    "goal": first_user_message,

    # Dimension 2: Progress (AI-provided, best-effort)
    "progress": progress if progress else None,

    # Dimension 3: Errors and failures
    "errors": errors if errors else None,

    # Dimension 4: Modified files (auto from git)
    "modified_files": modified_files if modified_files else None,

    # Dimension 5: Decisions (auto-extracted + AI-provided)
    "decisions": decisions if decisions else None,

    # Dimension 7: User directives
    "user_directives": user_directives if user_directives else None,
}

# Remove None values for cleaner JSON
snapshot = {k: v for k, v in snapshot.items() if v is not None}

with open(snapshot_path, "w", encoding="utf-8") as f:
    json.dump(snapshot, f, ensure_ascii=False, indent=2)
PYSCRIPT
