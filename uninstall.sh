#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="$HOME/.claude/tools/task-tracker"
SETTINGS_FILE="$HOME/.claude/settings.json"

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
if [ -z "$PYTHON" ]; then echo "ERROR: Python not found."; exit 1; fi

echo ""
echo "  Uninstalling Claude Task Tracker..."
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
