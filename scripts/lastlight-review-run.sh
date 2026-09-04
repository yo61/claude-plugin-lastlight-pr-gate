#!/usr/bin/env bash
# Run the Last Light PR review as an INDEPENDENT pass, in a fresh headless
# Claude session that did not write the code.
#
# WHY THIS EXISTS
#   The recorder alone cannot tell a real review from a hand-written
#   findings.json: it validates the schema and the pass bar, nothing else. An
#   agent reviewing its own work is exactly where that fails -- measured on
#   github-repos#82, a self-review missed a Critical that the server's review
#   caught. So the review is run by a separate `claude -p` session with no
#   memory of authoring the change, which is the property that makes the
#   server's review useful in the first place.
#
# WHAT IT DOES NOT FIX
#   This raises the bar; it does not make forgery impossible. Anyone who can
#   write findings.json can also write the attestation beside it. The point is
#   that the honest path is now also the easy path, and that a review is bound
#   to the exact diff it looked at.
#
# DELIBERATE DEVIATION FROM THE SKILL
#   The skill permits *probes* -- installing dependencies and executing code to
#   settle a question. This runner does not, because it runs unattended from a
#   push. Set LASTLIGHT_REVIEW_TOOLS to widen it if you want probe fidelity, and
#   know that you are granting a headless session execute access to the repo.
#
# THREAT MODEL -- the reviewed diff is UNTRUSTED INPUT
#   The prompt tells this session the code is not its own and not to be trusted.
#   That makes the diff an injection surface: a payload in a reviewed file or
#   comment can try to steer an unattended session with real tool access.
#
#   WRITES are therefore scoped to the single file the skill's contract needs,
#   via an `Edit(<findings.json>)` rule and NO bare `Write` -- a bare `Write`
#   entry is itself an unscoped allow and silently defeats the path rule
#   (verified). Without this, an injected instruction could overwrite
#   `lastlight-review-gate.sh` itself and silently disable the push gate this
#   plugin exists to enforce.
#
#   READS are NOT scoped: the reviewer must read the repo and the staged skill
#   assets, and file-permission rules only match `Edit(...)`. So a successful
#   injection could still exfiltrate anything the invoking user can read, given
#   an egress path. Treat that as the residual risk; do not run this over a
#   diff from a source you would not run code from.
#
# THE PROPER FIX, DESIGNED AND VERIFIED BUT NOT YET WIRED IN
#   Read-scoping and the no-probes restriction are both workarounds for running
#   an untrusted diff with the invoking user's full privileges. Isolating the
#   session removes the need for either -- and Claude Code already ships the
#   pieces, so this needs no container.
#
#   Two parts:
#     1. A DISPOSABLE COPY. Clone the repo at HEAD into a temp dir
#        (`git clone --no-hardlinks`) and review there, so nothing the session
#        writes can reach the real working tree or its .git.
#
#        A clone carries only COMMITTED state -- verified: local
#        committed-but-unpushed commits come across, uncommitted modifications
#        and untracked files do not. That is not a gap here, because the code
#        under review is committed by construction: the recorder refuses a
#        marker while the tree is dirty outside .lastlight/, and the marker
#        vouches for a SHA, which cannot describe a working tree.
#
#        It is in fact a fidelity GAIN. Last Light reviews a checkout of the PR
#        head -- committed code only -- so a clone matches what the server sees,
#        whereas reviewing in place lets the reviewer read untracked and
#        gitignored files the server never will.
#
#        The genuine consequence: this can never review work BEFORE it is
#        committed. The order is commit -> review -> record -> push, and acting
#        on a finding means a new commit and a fresh review. That is inherent to
#        keying on a SHA, not something the clone introduces.
#     2. THE BUILT-IN SANDBOX, passed to `claude -p --settings`:
#          sandbox.enabled: true
#          sandbox.filesystem.allowWrite: [<the temp clone>]
#          sandbox.filesystem.denyRead:  [~/.ssh, ~/.aws, ~/.claude, .envrc, ...]
#          sandbox.network.allowedDomains: [api.anthropic.com, ...]
#          sandbox.credentials.envVars:  deny/mask the tokens
#
#   All four controls were verified on macOS (Seatbelt, sandbox-exec) on
#   2026-09-04: a write inside allowWrite succeeded; a read of a denied path was
#   refused; a write outside allowWrite was refused; and egress to a domain
#   outside allowedDomains was refused. The last is the one that actually closes
#   exfiltration, which read-scoping alone never could.
#
#   With that in place the read restriction stops mattering and PROBES become
#   safe to re-enable -- which is the point, because a probe is what caught a
#   real safety bug that static reading missed (an `rm -rf` exemption that let
#   a disposable argument exempt a protected path beside it). The affordance
#   this runner currently withholds is the one that found the bug.
#
# Usage:
#   lastlight-review-run.sh [--model <m>] [base-ref]   # base: merge-base with origin/HEAD
#
# Env:
#   LASTLIGHT_REVIEW_MODEL    model for the reviewer (default: sonnet, matching
#                             Last Light's own models.default). Also --model <m>.
#   LASTLIGHT_REVIEW_TIMEOUT  seconds (default 900)
#   LASTLIGHT_REVIEW_TOOLS    override the allowed-tools list
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SELF_DIR
readonly ASSETS="${LASTLIGHT_REVIEW_DIR:-$HOME/.claude/lastlight-review}"
readonly OUT_DIR=.lastlight/pr-review
readonly TIMEOUT="${LASTLIGHT_REVIEW_TIMEOUT:-900}"
# Read-only exploration plus the one Write the skill's contract requires.
# An ARRAY, not a string: these contain spaces and parentheses, so a word-split
# string turns `Bash(git diff:*)` into two malformed rules that the CLI ignores
# with a warning -- leaving the reviewer unable to run git at all.
# NOTE the absence of a bare `Write`: that would be an unscoped allow and would
# silently defeat the `Edit(<findings.json>)` rule appended in main(). Writes
# must stay confined to the one file the contract requires.
readonly DEFAULT_TOOLS=(
  Read Grep Glob
  'Bash(git diff:*)' 'Bash(git log:*)' 'Bash(git show:*)'
  'Bash(git status:*)' 'Bash(rg:*)' 'Bash(fd:*)'
)
# Matches Last Light's own `models.default` (anthropic/claude-sonnet-4-6), which
# is what its `review` phase falls back to when `models.review` is unset and
# analysis is disabled. Pinning the tier here rather than inheriting the CLI
# default keeps the local pass comparable to the server's -- and stops a review
# silently running on whatever model the invoking session happened to use.
readonly DEFAULT_MODEL=sonnet

die() {
  printf 'lastlight-review-run: %s\n' "$1" >&2
  exit 1
}

main() {
  command -v claude > /dev/null 2>&1 || die "the claude CLI is required"
  command -v jq > /dev/null 2>&1 || die "jq is required"

  # Model resolution, most specific first: --model flag, env, then the pinned
  # default. Recorded in the attestation so a review can always be traced to
  # the model that produced it.
  MODEL=${LASTLIGHT_REVIEW_MODEL:-$DEFAULT_MODEL}
  if [[ ${1:-} == --model ]]; then
    [[ -n ${2:-} ]] || die "--model needs a value"
    MODEL=$2
    shift 2
  fi
  readonly MODEL

  local root sha base
  root=$(git rev-parse --show-toplevel 2> /dev/null) || die "not inside a git repository"
  cd "$root"
  sha=$(git rev-parse HEAD)

  base=${1:-}
  if [[ -z $base ]]; then
    local default_ref
    default_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null || true)
    [[ -n $default_ref ]] || default_ref=origin/main
    git rev-parse --verify --quiet "$default_ref" > /dev/null 2>&1 || default_ref=origin/master
    base=$(git merge-base HEAD "$default_ref" 2> /dev/null) \
      || die "could not find a merge base with ${default_ref}; pass a base ref explicitly"
  fi

  [[ -f "$ASSETS/skills/pr-review/SKILL.md" ]] \
    || die "review assets not staged -- run lastlight-review-sync.sh first"

  mkdir -p "$OUT_DIR"

  # Three-dot: what this branch adds, not what main did meanwhile (SKILL.md §3).
  git diff "$base"...HEAD > "$OUT_DIR/diff.patch"
  if [[ ! -s "$OUT_DIR/diff.patch" ]]; then
    die "empty diff against ${base:0:12} -- nothing to review"
  fi
  local diff_hash
  diff_hash=$(git hash-object "$OUT_DIR/diff.patch")

  # A stale findings.json would bias an "independent" pass, and the skill is
  # explicit that a finding copied from another stage is one the adjudicator can
  # no longer cross-check. Start clean.
  rm -f "$OUT_DIR/findings.json" "$OUT_DIR/attestation.json"

  local -a tools=("${DEFAULT_TOOLS[@]}")
  if [[ -n ${LASTLIGHT_REVIEW_TOOLS:-} ]]; then
    IFS=',' read -r -a tools <<< "$LASTLIGHT_REVIEW_TOOLS"
  fi
  # The ONE write the contract needs, scoped to exactly that path. Appended
  # after any override so widening the tool list cannot accidentally drop the
  # reviewer's ability to record its own result.
  #
  # RELATIVE, and main() has already cd'd to $root. A bare absolute path does
  # NOT match (verified: the reviewer was then unable to write its own findings,
  # which would have failed every run closed); the absolute form needs a `//`
  # prefix. The relative form sidesteps that entirely.
  tools+=("Edit(${OUT_DIR}/findings.json)")

  printf 'Reviewing %s against %s\n  model: %s (independent session)\n' \
    "${sha:0:12}" "${base:0:12}" "$MODEL" >&2

  if ! timeout "$TIMEOUT" claude -p "$(prompt "$root" "$base" "$sha")" \
    --allowed-tools "${tools[@]}" \
    --model "$MODEL" > "$OUT_DIR/reviewer.log" 2>&1; then
    die "the reviewer session failed or timed out; see $OUT_DIR/reviewer.log"
  fi

  # A rule the CLI could not parse leaves the reviewer without a tool it needed,
  # and it will carry on and produce a thinner review rather than fail. Treat
  # that as a hard error: a silently under-equipped reviewer is worse than none.
  if rg -q 'Ignoring --allowedTools rule' "$OUT_DIR/reviewer.log" 2> /dev/null; then
    die "the CLI rejected an allowed-tools rule, so the reviewer ran under-equipped; see $OUT_DIR/reviewer.log"
  fi

  [[ -f "$OUT_DIR/findings.json" ]] \
    || die "the reviewer wrote no findings.json; see $OUT_DIR/reviewer.log"
  jq -e . "$OUT_DIR/findings.json" > /dev/null 2>&1 \
    || die "the reviewer wrote invalid JSON to findings.json"

  # Binds the review to the exact diff it saw. The recorder refuses a marker
  # whose attestation does not match the current HEAD and diff.
  jq -n \
    --arg sha "$sha" \
    --arg base "$base" \
    --arg diff "$diff_hash" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg model "$MODEL" \
    '{sha:$sha, base:$base, diffHash:$diff, reviewedAt:$at, runner:"independent-session", model:$model}' \
    > "$OUT_DIR/attestation.json"

  printf 'Review complete: event=%s findings=%s\n' \
    "$(jq -r '.event // "?"' "$OUT_DIR/findings.json")" \
    "$(jq -r '(.findings // []) | length' "$OUT_DIR/findings.json")" >&2
  printf 'Next: %s/lastlight-review-record.sh\n' "$SELF_DIR" >&2
}

prompt() {
  local root=$1 base=$2 sha=$3
  cat << PROMPT
You are reviewing a pull request. You did NOT write this code — review it as an
independent reviewer would, and do not assume the author's reasoning was sound.

Follow the instructions in this skill file EXACTLY, including its findings
schema and its precision bar:

  ${ASSETS}/skills/pr-review/SKILL.md
  ${ASSETS}/skills/pr-review/references/findings-schema.md

Its companion skill, referenced by that file, is at:

  ${ASSETS}/skills/code-review/SKILL.md

Context for the review:
  repository root : ${root}
  head SHA        : ${sha}
  base            : ${base}
  three-dot diff  : ${root}/${OUT_DIR}/diff.patch  (already generated)

Read the diff, then read the surrounding code in this checkout to judge it —
never assume a hunk is correct because it looks self-consistent.

Write your result to ${root}/${OUT_DIR}/findings.json in the skill's schema
(skip? / summary / event / findings[]). An empty findings array is a valid
outcome when the falsifying looks came up empty — but it must be earned, not
assumed. Report Critical and Important findings only.

Do not post anything to GitHub. Do not modify any file other than
findings.json. You are the only reviewer; there is no later stage to catch what
you skip.
PROMPT
}

main "$@"
