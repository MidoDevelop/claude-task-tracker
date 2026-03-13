#!/usr/bin/env bash
# Claude Code wrapper: 检测到未完成任务快照时自动发送恢复消息
# 用法：用 alias 替代 claude 命令，或直接 source 此脚本

claude_wrapper() {
  local snapshot_dir="$HOME/.claude/task-snapshots"
  local real_claude="/Users/nick/.local/bin/claude"

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
