#!/usr/bin/env bash
# Record that the Last Light PR review ran locally and passed, for one exact
# HEAD SHA. Writes the marker `lastlight-review-gate.sh` looks for.
#
# THE PASS BAR (Robin's choice, 2026-09-04): findings must be empty, OR every
# finding must be dismissed with a written reason. A disputed finding must not
# be able to strand a push -- the review skill's own bar is precision, and it
# can be wrong -- but a dismissal has to be *stated*, not assumed.
#
# Inputs, relative to the repo root:
#   .lastlight/pr-review/findings.json    written by the pr-review skill, in its
#                                         own schema. Left PRISTINE.
#   .lastlight/pr-review/dismissed.json   sidecar, {"<finding title>": "reason"}.
#                                         Separate file so findings.json stays
#                                         schema-faithful and diffable against
#                                         what the server would have produced.
#
# Usage: lastlight-review-record.sh [sha]     (default: HEAD)
set -euo pipefail

readonly MARKER_DIR=lastlight-local-review
readonly FINDINGS=.lastlight/pr-review/findings.json
readonly DISMISSED=.lastlight/pr-review/dismissed.json
# Long enough that "n/a", "ok" and "wontfix" do not clear the bar.
readonly MIN_REASON=25

die() {
  printf 'lastlight-review-record: %s\n' "$1" >&2
  exit 1
}

main() {
  command -v jq > /dev/null 2>&1 || die "jq is required"

  local root sha head
  root=$(git rev-parse --show-toplevel 2> /dev/null) || die "not inside a git repository"
  head=$(git rev-parse HEAD)
  sha=${1:-$head}
  # Accept an abbreviated sha, but store the full one -- the gate keys on it.
  sha=$(git rev-parse "$sha" 2> /dev/null) || die "not a valid revision: ${1:-HEAD}"

  if [[ $sha != "$head" ]]; then
    die "refusing: you reviewed ${sha:0:12} but HEAD is now ${head:0:12}. Re-review at HEAD -- that is the SHA the server will bill for."
  fi
  # `.lastlight/` is the review's OWN output directory, so it is dirty by
  # construction the moment the review runs. Excluding it is required, not a
  # convenience -- without this the recorder can never succeed.
  if [[ -n $(git status --porcelain -- ':(exclude).lastlight/') ]]; then
    die "refusing: the working tree has uncommitted changes outside .lastlight/, so the review did not cover what will be pushed. Commit or stash first."
  fi

  [[ -f "$root/$FINDINGS" ]] || die "no $FINDINGS -- run the review first (see ~/.claude/lastlight-review/skills/pr-review/SKILL.md)"
  jq -e . "$root/$FINDINGS" > /dev/null 2>&1 || die "$FINDINGS is not valid JSON"

  local skip count event
  skip=$(jq -r '.skip // false' "$root/$FINDINGS")
  event=$(jq -r '.event // "MISSING"' "$root/$FINDINGS")
  count=$(jq -r '(.findings // []) | length' "$root/$FINDINGS")

  if [[ $skip != true && $event == MISSING ]]; then
    die "$FINDINGS has no \`event\` -- it must be APPROVE, REQUEST_CHANGES or COMMENT (see the skill's findings schema)"
  fi

  local dismissed_n=0
  if [[ $skip != true && $count -gt 0 ]]; then
    require_dismissals "$root" "$count"
    dismissed_n=$count
  fi

  local marker_dir
  marker_dir="$(git rev-parse --git-dir)/$MARKER_DIR"
  mkdir -p "$marker_dir"
  jq -n \
    --arg sha "$sha" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$event" \
    --arg core "$(cat "$HOME/.claude/lastlight-review/.version" 2> /dev/null || echo unknown)" \
    --arg skill "$(sed -n 's/^version: //p' "$HOME/.claude/lastlight-review/skills/pr-review/SKILL.md" 2> /dev/null | head -1)" \
    --argjson findings "$count" \
    --argjson dismissed "$dismissed_n" \
    '{sha:$sha, reviewedAt:$at, event:$event, findings:$findings, dismissed:$dismissed,
      assets:{lastlightCore:$core, prReviewSkill:$skill}}' \
    > "$marker_dir/$sha.json"

  printf 'Recorded local review of %s\n' "${sha:0:12}"
  printf '  event: %s, findings: %s, dismissed: %s\n' "$event" "$count" "$dismissed_n"
  printf '  assets: lastlight-core %s, pr-review skill %s\n' \
    "$(cat "$HOME/.claude/lastlight-review/.version" 2> /dev/null || echo '?')" \
    "$(sed -n 's/^version: //p' "$HOME/.claude/lastlight-review/skills/pr-review/SKILL.md" 2> /dev/null | head -1)"
  printf '  push is now unblocked for this SHA. Any new commit invalidates it.\n'
}

# Every finding title must carry a substantive dismissal reason.
require_dismissals() {
  local root=$1 count=$2 title reason missing=0
  [[ -f "$root/$DISMISSED" ]] || die "$count finding(s) recorded but no $DISMISSED. Fix them, or dismiss each with a reason: {\"<finding title>\": \"why this is not a problem\"}"
  jq -e . "$root/$DISMISSED" > /dev/null 2>&1 || die "$DISMISSED is not valid JSON"

  while IFS= read -r title; do
    reason=$(jq -r --arg t "$title" '.[$t] // ""' "$root/$DISMISSED")
    if [[ -z $reason ]]; then
      printf '  UNDISMISSED: %s\n' "$title" >&2
      missing=1
    elif [[ ${#reason} -lt $MIN_REASON ]]; then
      printf '  REASON TOO THIN (%d chars, need %d): %s\n' "${#reason}" "$MIN_REASON" "$title" >&2
      missing=1
    fi
  done < <(jq -r '(.findings // [])[] | .title' "$root/$FINDINGS")

  [[ $missing -eq 0 ]] || die "every finding must be fixed or dismissed with a stated reason"
}

main "$@"
