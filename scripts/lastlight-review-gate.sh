#!/usr/bin/env bash
# Gate: no unreviewed SHA reaches a remote.
#
# GOAL (Robin, 2026-09-04): "I want to prevent unreviewed SHAs getting pushed --
# anything that lands remotely will be reviewed, I accept that."
#
# So this is NOT conditional on a PR existing. Every commit that lands on a
# remote must first have been reviewed locally at that exact SHA, because
# anything on a remote is eventually reviewed by Last Light: the `pr.opened`
# webhook, or `check-prs-awaiting-review` sweeping every 30 minutes
# (cron-review.yaml). Reviewing locally first is what stops a round-trip.
#
# That unconditional rule is also what makes this gate DETERMINISTIC. An earlier
# version asked GitHub "does this branch have an open PR?", which needed the
# network, needed `gh`, and had to fail OPEN when either was unavailable. Asking
# only "does this SHA have a marker?" is a local filesystem question, so the gate
# now FAILS CLOSED and needs no network at all.
#
# ALLOWED without a marker, because no new commit reaches the remote:
#   - deleting a ref (`--delete`, or a `:branch` refspec with an empty source)
#   - pushing tags only (`--tags`, or a `refs/tags/...` refspec)
#   - a dry run (`--dry-run`)
# Also allowed: anything outside a git repo, and repos that opt out.
#
# KNOWN FALSE POSITIVE: `grep` matches line-by-line, so a heredoc that WRITES a
# script containing `git push` trips this. Rare, and recoverable -- use the
# per-repo opt-out, or write the file with the Write tool instead.
#
# Marker: .git/lastlight-local-review/<sha>.json, written by
# lastlight-review-record.sh, which enforces the pass bar. Keyed by SHA, so a new
# commit, amend or rebase correctly re-arms the gate -- which is what makes
# "iterate locally until clean" structural rather than a matter of discipline:
# fixing a finding produces a new SHA, and the new SHA needs its own review.
#
# Opt out for a repo: touch "$(git rev-parse --git-dir)/lastlight-review-gate-off"
#
# See ~/knowledge/lastlight/knowledge.md
set -euo pipefail

# Sibling scripts are addressed relative to this file, so the guidance in a deny
# message stays correct whether this is installed under ~/.claude/hooks or
# inside a plugin (where it lives at $CLAUDE_PLUGIN_ROOT/scripts).
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SELF_DIR

readonly MARKER_DIR=lastlight-local-review

allow() { exit 0; }

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# `sed -E` throughout: BSD sed's BRE has no `\|` alternation (a GNU extension),
# so `\(cd\|pushd\)` silently matches NOTHING on macOS -- which is exactly how
# `cd repo && git push` leaked past an earlier version of this gate.
resolve_target() {
  local cmd=$1 fallback=$2 p
  p=$(sed -E -n 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:];&|)]*).*/\1/p' <<< "$cmd" | head -1)
  if [[ -z $p ]]; then
    p=$(sed -E -n 's/.*(^|[^[:alnum:]_-])(cd|pushd)[[:space:]]+([^;&|)]*).*/\3/p' <<< "$cmd" | head -1 | sed 's/[[:space:]]*$//')
  fi
  p=${p%\"}
  p=${p#\"}
  p=${p%\'}
  p=${p#\'}
  p=${p/#\~/$HOME}
  if [[ -n $p && -d $p ]]; then printf '%s' "$p"; else printf '%s' "$fallback"; fi
}

# Arguments belonging to the `git push`, up to the next command separator.
push_args() {
  sed -E -n 's/.*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push[[:space:]]*([^;&|]*).*/\2/p' <<< "$1" | head -1
}

# Local revisions whose commits would land remotely, one per line. Empty output
# means "nothing lands" (tag-only, deletion) OR "could not tell" -- the caller
# distinguishes the two, because those must not share a verdict.
pushed_revs() {
  local args=$1 tok seen_remote=0 skip_next=0
  for tok in $args; do
    # Redirections are not refs. `git push ... 2>&1 | tail` was read as a ref
    # named `2>` and denied a properly reviewed SHA, so these are stripped
    # first. A bare operator (`>`, `2>>`) takes the NEXT token as its target;
    # a joined form (`2>&1`, `>/dev/null`) carries its own.
    if [[ $skip_next -eq 1 ]]; then
      skip_next=0
      continue
    fi
    if [[ $tok =~ ^[0-9]*(\>\>|\>|\<)$ ]]; then
      skip_next=1
      continue
    fi
    [[ $tok =~ ^[0-9]*(\>|\<) ]] && continue
    [[ $tok == '&>'* ]] && continue

    case $tok in
      -*) continue ;;
      *:*)
        # `src:dst`. An empty src is a deletion; a refs/tags/ dst carries no
        # commits of its own.
        seen_remote=1
        # `-` marks an EXPLICIT ref that carries no commits. It must be
        # distinguishable from "no refs given at all", which means HEAD.
        if [[ -z ${tok%%:*} || ${tok#*:} == refs/tags/* ]]; then
          printf -- '-\n'
          continue
        fi
        printf '%s\n' "${tok%%:*}"
        ;;
      refs/tags/*)
        seen_remote=1
        printf -- '-\n'
        continue
        ;;
      *)
        # The FIRST bare token is the REMOTE, not a ref -- `git push origin main`
        # is remote `origin`, ref `main`. Treating it as a revision made
        # `git push -u origin HEAD` fail to resolve and deny a reviewed SHA.
        if [[ $seen_remote -eq 0 ]]; then
          seen_remote=1
          continue
        fi
        printf '%s\n' "$tok"
        ;;
    esac
  done
}

# Opening or un-drafting a PR surfaces HEAD for review. Once pushes are gated
# this is normally already satisfied; it exists for branches that predate the
# gate.
gate_pr_open() {
  local cmd=$1 cwd=$2 target gitdir head
  target=$(resolve_target "$cmd" "$cwd")
  [[ -n $target && -d $target ]] || allow
  gitdir=$(git -C "$target" rev-parse --git-dir 2> /dev/null) || allow
  [[ $gitdir = /* ]] || gitdir="$target/$gitdir"
  [[ -e "$gitdir/lastlight-review-gate-off" ]] && allow
  head=$(git -C "$target" rev-parse HEAD 2> /dev/null) || allow
  [[ -f "$gitdir/$MARKER_DIR/$head.json" ]] && allow
  deny "$(gate_message "$head" "This opens or un-drafts a PR at ${head:0:12}, which has no local review recorded.")"
}

main() {
  command -v jq > /dev/null 2>&1 || allow

  local payload cmd cwd
  payload=$(cat)
  cmd=$(jq -r '.tool_input.command // empty' <<< "$payload" 2> /dev/null) || allow
  cwd=$(jq -r '.cwd // empty' <<< "$payload" 2> /dev/null)
  [[ -n $cmd ]] || allow

  # FAST PATH: runs on every Bash call, so all git work sits behind this.
  # PR-opening is included as belt-and-braces. Once every push is gated, HEAD
  # always has a marker by the time a PR is opened, so this adds no friction --
  # but it still catches a branch pushed BEFORE this gate existed.
  local opens=0
  grep -Eq '(^|[;|&(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|ready|reopen)([[:space:]]|$|\))' <<< "$cmd" && opens=1
  grep -Eq '(^|[;|&(])[[:space:]]*gh[[:space:]]+api[^;|&]*(/pulls|repos/[^[:space:]]*/pulls)' <<< "$cmd" && opens=1
  if [[ $opens -eq 0 ]]; then
    grep -Eq '(^|[;|&(])[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$|\))' <<< "$cmd" || allow
  fi

  local args
  args=$(push_args "$cmd")

  if [[ $opens -eq 1 ]]; then
    gate_pr_open "$cmd" "$cwd"
  fi

  # Nothing lands: deletions, tag-only pushes, dry runs.
  grep -Eq '(^|[[:space:]])(--delete|-d|--dry-run)([[:space:]]|$)' <<< "$args" && allow
  if grep -Eq '(^|[[:space:]])--tags([[:space:]]|$)' <<< "$args"; then
    [[ -z $(pushed_revs "$args") ]] && allow
  fi

  local target gitdir
  target=$(resolve_target "$cmd" "$cwd")
  [[ -n $target && -d $target ]] || allow
  gitdir=$(git -C "$target" rev-parse --git-dir 2> /dev/null) || allow
  [[ $gitdir = /* ]] || gitdir="$target/$gitdir"
  [[ -e "$gitdir/lastlight-review-gate-off" ]] && allow

  # `--all` / `--mirror` push a set this cannot enumerate from the command line.
  if grep -Eq '(^|[[:space:]])(--all|--mirror)([[:space:]]|$)' <<< "$args"; then
    deny "$(gate_message "$(git -C "$target" rev-parse HEAD 2> /dev/null || echo HEAD)" \
      'A --all/--mirror push sends refs this gate cannot enumerate, so it cannot confirm every SHA was reviewed.')"
  fi

  local revs real
  revs=$(pushed_revs "$args")
  if [[ -z $revs ]]; then
    # No explicit ref: bare `git push` sends the current branch.
    revs=HEAD
  else
    real=$(grep -v '^-$' <<< "$revs" || true)
    # Every explicit ref was a tag or a deletion -- nothing new lands.
    [[ -n $real ]] || allow
    revs=$real
  fi

  local rev sha
  while IFS= read -r rev; do
    [[ -n $rev ]] || continue
    if ! sha=$(git -C "$target" rev-parse --verify "$rev^{commit}" 2> /dev/null); then
      # An unresolvable ref means the gate cannot prove the SHA was reviewed.
      # Fail CLOSED -- there is no network excuse here, only an unparsed command.
      deny "$(gate_message "unknown" "Could not resolve '${rev}' to a commit, so this gate cannot confirm what would land remotely.")"
    fi
    if [[ ! -f "$gitdir/$MARKER_DIR/$sha.json" ]]; then
      deny "$(gate_message "$sha" "${sha:0:12} (${rev}) has no local review recorded, and pushing it puts an unreviewed SHA on the remote.")"
    fi
  done <<< "$revs"

  allow
}

gate_message() {
  local sha=$1 why=$2
  cat << MSG
Blocked by ~/.claude/hooks/lastlight-review-gate.sh:

${why}

Anything that lands on a remote gets reviewed by Last Light -- on the pr.opened
webhook, or by the 30-minute check-prs-awaiting-review sweep. Reviewing locally
first is what stops that becoming a round trip.

Run the SAME review Last Light would run -- it is the identical skill:

1. Check the assets are staged and unmodified:
     ${SELF_DIR}/lastlight-review-sync.sh --check
2. Follow ~/.claude/lastlight-review/skills/pr-review/SKILL.md against the
   three-dot diff for this branch, writing .lastlight/pr-review/findings.json
   in that skill's schema.
3. Fix what it finds, or dismiss each finding with a written reason in
   .lastlight/pr-review/dismissed.json.
4. Record the pass:
     ${SELF_DIR}/lastlight-review-record.sh ${sha:0:12}

Then push. Batch fixes into ONE push: each new head SHA is another review.

Not gated: ref deletions, tag-only pushes, and --dry-run, since no new commit
reaches the remote.

Opt out for this repo: touch "\$(git rev-parse --git-dir)/lastlight-review-gate-off"
MSG
}

main "$@"
