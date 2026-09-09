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

# Sibling scripts are addressed relative to this file, so the guidance in an
# error stays correct whether this is installed under ~/.claude/hooks or inside
# a plugin (where it lives at $CLAUDE_PLUGIN_ROOT/scripts).
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SELF_DIR

readonly MARKER_DIR=lastlight-local-review
readonly FINDINGS=.lastlight/pr-review/findings.json
readonly DISMISSED=.lastlight/pr-review/dismissed.json
# Written by lastlight-review-run.sh; binds a review to the diff it read.
readonly ATTESTATION=.lastlight/pr-review/attestation.json
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

  # A review recorded inside a work clone unlocks nothing that should be
  # unlocked: the push gate refuses that clone outright, and the marker would
  # sit in a git dir the session can write. Refusing here stops the ordinary
  # mistake -- finishing in the workspace and recording there -- at the point it
  # is made, rather than at the push.
  local registry=${LASTLIGHT_WORKSPACE_REGISTRY:-$HOME/.lastlight/workspaces}
  local entry recorded here
  here=$(cd "$root" 2> /dev/null && pwd -P) || here=""
  if [[ -n $here && -d $registry ]]; then
    for entry in "$registry"/*; do
      [[ -f $entry ]] || continue
      recorded=$(head -1 "$entry" 2> /dev/null) || continue
      [[ -n $recorded ]] || continue
      recorded=$(cd "$recorded" 2> /dev/null && pwd -P) || continue
      [[ $recorded == "$here" ]] || continue
      die "this is a work sandbox workspace; land the work first, then review and record in the repository it came from"
    done
  fi

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

  [[ -f "$root/$FINDINGS" ]] || die "no $FINDINGS -- run the review first: ${SELF_DIR}/lastlight-review-run.sh"
  jq -e . "$root/$FINDINGS" > /dev/null 2>&1 || die "$FINDINGS is not valid JSON"

  require_attestation "$root" "$sha"

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
  local gitdir
  gitdir=$(git rev-parse --git-dir)
  marker_dir="$gitdir/$MARKER_DIR"
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

# The review must have come from lastlight-review-run.sh, and must have looked
# at THIS diff. Without this, findings.json is just a file anyone can write, and
# an agent reviewing its own work can approve itself in one line -- which is the
# exact failure this whole flow exists to avoid.
#
# Not tamper-proof: whoever can write findings.json can write the attestation
# too. It makes the independent path the easy path, and binds a review to the
# diff it actually saw, so a stale review cannot silently vouch for new code.
require_attestation() {
  local root=$1 sha=$2 recorded_sha recorded_diff current_diff base
  local att="$root/$ATTESTATION"

  [[ -f $att ]] || die "no $ATTESTATION -- findings.json alone is not evidence a review happened. Run: ${SELF_DIR}/lastlight-review-run.sh"
  jq -e . "$att" > /dev/null 2>&1 || die "$ATTESTATION is not valid JSON"

  recorded_sha=$(jq -r '.sha // ""' "$att")
  [[ $recorded_sha == "$sha" ]] \
    || die "the review attests to ${recorded_sha:0:12}, but HEAD is ${sha:0:12}. Re-run the review at HEAD."

  # Recompute the diff the review claims to have read. A matching SHA is not
  # enough on its own -- this also catches an attestation copied from elsewhere.
  base=$(jq -r '.base // ""' "$att")
  [[ -n $base ]] || die "$ATTESTATION records no base ref"
  recorded_diff=$(jq -r '.diffHash // ""' "$att")
  current_diff=$(git diff "$base"...HEAD | git hash-object --stdin)
  [[ $recorded_diff == "$current_diff" ]] \
    || die "the diff has changed since the review (attested ${recorded_diff:0:12}, now ${current_diff:0:12}). Re-run the review."
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
