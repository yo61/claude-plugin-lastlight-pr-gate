#!/usr/bin/env bash
# Close the MCP bypass on the PR-review gate.
#
# `lastlight-review-gate.sh` inspects Bash commands. The GitHub MCP server
# reaches GitHub without a shell at all, so `create_pull_request` and
# `push_files` sail straight past it. Verified 2026-09-04 that PreToolUse hooks
# DO fire on `mcp__*` tool names, so the hole is closeable.
#
# These tools take `owner`/`repo`/`branch` arguments rather than operating in a
# working directory, so there is no reliable way to map one onto a local
# checkout and check its review marker. Rather than guess, this refuses and
# points at the equivalent `gh` command -- which the Bash gate CAN verify.
#
# Gated (each creates a PR or a new head SHA on one):
#   create_pull_request, update_pull_request, push_files, create_or_update_file
#
# NOT gated: everything read-only, plus merge/branch/issue tools, none of which
# create an unreviewed head SHA on an open PR.
set -euo pipefail

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

main() {
  command -v jq > /dev/null 2>&1 || exit 0

  local payload tool
  payload=$(cat)
  tool=$(jq -r '.tool_name // empty' <<< "$payload" 2> /dev/null) || exit 0

  local equivalent
  case $tool in
    *create_pull_request) equivalent='gh pr create' ;;
    *update_pull_request) equivalent='gh pr edit / gh pr ready' ;;
    *push_files | *create_or_update_file) equivalent='git commit && git push' ;;
    *) exit 0 ;;
  esac

  deny "Blocked by ~/.claude/hooks/lastlight-mcp-pr-gate.sh:

${tool} reaches GitHub without a shell, so the PR-review gate cannot see it --
and because it addresses a repo by owner/name rather than a working directory,
there is no local checkout whose review marker could be checked.

Use \`${equivalent}\` in a local checkout instead. That path goes through
lastlight-review-gate.sh, which verifies a local review ran at the exact SHA
before letting an unreviewed commit reach a remote.

If this repo genuinely is not managed by Last Light, disable the gate for its
checkout: touch \"\$(git rev-parse --git-dir)/lastlight-review-gate-off\""
}

main "$@"
