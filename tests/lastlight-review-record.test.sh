#!/usr/bin/env bash
# Test suite for lastlight-review-record.sh's attestation check.
#
# This is the mechanism the plugin is named for: it is what stops a hand-written
# findings.json being accepted as a real review, and what stops a review of one
# diff vouching for another. It shipped with no test proving it rejects a forged
# or stale attestation, which the independent review flagged.
#
# Run: bash tests/lastlight-review-record.test.sh
set -uo pipefail
# Default to the copy IN THIS REPO, not the one installed under ~/.claude.
# A suite that defaults to the installed copy tests whatever the machine
# happens to have: it passes on a developer box that already has the plugin
# and fails outright on a fresh checkout, which is every CI runner. The three
# newer suites here already resolve from ../scripts; these two did not, so
# `tests/readme-counts.sh` -- which invokes each suite with no environment --
# broke in CI and in the pre-commit hook for anyone without an install.
#
# The override still works, and CI still passes one explicitly.
# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
clear_inherited_config
RECORD="${RECORD:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lastlight-review-record.sh}"
# Resolve to an ABSOLUTE path up front. Every case below cd's into a throwaway
# fixture repo before invoking $RECORD, so a relative path stops resolving and
# bash exits 127 -- which expect() reads as a refusal, silently turning the two
# `expect pass` cases red. The prek hook passes a relative path while CI passes
# an absolute one, so this broke the local hook on every commit while CI stayed
# green. Identical to the bug already fixed in the sibling guard suite; fixing
# it there and reintroducing it here is why the resolution belongs in a shared
# place, not copied per-suite.
RECORD=$(cd "$(dirname "$RECORD")" && printf '%s/%s' "$PWD" "$(basename "$RECORD")")
pass=0
fail=0

TMP=$(mktemp -d)
REPO=$TMP/repo
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo base > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm "feat: base"
git -C "$REPO" branch base
echo work >> "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm "feat: work"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

OUT="$REPO/.lastlight/pr-review"
mkdir -p "$OUT"

findings() { # findings <event> [findings-json]
  jq -n --arg e "$1" --argjson f "${2:-[]}" \
    '{skip:false, summary:"test", event:$e, findings:$f}' > "$OUT/findings.json"
}

attest() { # attest <sha> <base> <diffhash>
  jq -n --arg s "$1" --arg b "$2" --arg d "$3" \
    '{sha:$s, base:$b, diffHash:$d, reviewedAt:"now", runner:"independent-session", model:"test"}' \
    > "$OUT/attestation.json"
}

real_diff_hash() { git -C "$REPO" diff base...HEAD | git hash-object --stdin; }
head_sha() { git -C "$REPO" rev-parse HEAD; }

expect() { # expect <pass|refuse> <label>
  local want=$1 label=$2 got
  if (cd "$REPO" && "$RECORD" > /dev/null 2>&1); then got=pass; else got=refuse; fi
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL want=%-6s got=%-6s : %s\n' "$want" "$got" "$label"
  fi
  rm -rf "$REPO/.git/lastlight-local-review"
}

echo "--- the forged-review case this exists to stop ---"
findings APPROVE
rm -f "$OUT/attestation.json"
expect refuse "hand-written findings.json, no attestation"

echo "--- attestation must match THIS head ---"
findings APPROVE
attest "0000000000000000000000000000000000000000" base "$(real_diff_hash)"
expect refuse "attestation for a different SHA"

echo "--- attestation must match THIS diff ---"
findings APPROVE
attest "$(head_sha)" base "0000000000000000000000000000000000000000"
expect refuse "stale diff hash"

echo "--- a well-formed attestation is accepted ---"
findings APPROVE
attest "$(head_sha)" base "$(real_diff_hash)"
expect pass "matching sha + diff hash"

echo "--- malformed inputs ---"
findings APPROVE
attest "$(head_sha)" base "$(real_diff_hash)"
echo 'not json' > "$OUT/attestation.json"
expect refuse "attestation is not valid JSON"

findings APPROVE
jq -n '{sha:"x", diffHash:"y"}' > "$OUT/attestation.json"
expect refuse "attestation records no base ref"

echo "--- the pass bar still applies on top of a valid attestation ---"
findings REQUEST_CHANGES '[{"path":"f.txt","existingCode":"work","severity":"Important","title":"A finding","body":"b"}]'
attest "$(head_sha)" base "$(real_diff_hash)"
rm -f "$OUT/dismissed.json"
expect refuse "finding present, no dismissal"

findings REQUEST_CHANGES '[{"path":"f.txt","existingCode":"work","severity":"Important","title":"A finding","body":"b"}]'
attest "$(head_sha)" base "$(real_diff_hash)"
jq -n '{"A finding":"too short"}' > "$OUT/dismissed.json"
expect refuse "dismissal reason below the minimum length"

findings REQUEST_CHANGES '[{"path":"f.txt","existingCode":"work","severity":"Important","title":"A finding","body":"b"}]'
attest "$(head_sha)" base "$(real_diff_hash)"
jq -n '{"A finding":"Compensated by the caller, which already validates this input upstream."}' > "$OUT/dismissed.json"
expect pass "finding dismissed with a substantive reason"

echo "--- a dirty tree outside .lastlight/ is refused ---"
findings APPROVE
attest "$(head_sha)" base "$(real_diff_hash)"
echo uncommitted >> "$REPO/f.txt"
expect refuse "uncommitted changes outside .lastlight/"
git -C "$REPO" checkout -q -- f.txt

echo "--- the exclusion pathspec must match the shared one ---"
# This script sources nothing: the recorder has to work without the sandbox
# machinery, so it carries its own copy of the pathspec. That is exactly the
# drift that let a previous review's artefacts into the next review's
# workspace, so the copy is checked against the definition rather than kept
# in step by hand.
#
# `expect` runs the recorder; these compare strings, so they need their own.
same() {
  local label=$1 got=$2 want=$3
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$label" "$want" "$got"
  fi
}

# grep, not rg: this suite must not depend on a tool the plugin does not
# require, which is a bug already fixed once in the runner.
SHARED=$(grep -o "^readonly LASTLIGHT_EXCLUDE=.*" "$(dirname "$RECORD")/lastlight-sandbox.sh" \
  | sed "s/^readonly LASTLIGHT_EXCLUDE=//; s/^'//; s/'\$//")
same "the shared constant is readable" "$([[ -n $SHARED ]] && echo yes || echo no)" "yes"
same "the recorder uses the same pathspec" "$(grep -c -F -- "$SHARED" "$RECORD")" "1"

echo "--- the recorder refuses inside a work workspace ---"
# Recording there unlocks nothing that should be unlocked, and the ordinary
# mistake is to finish in the workspace and record on the spot. Refusing at
# the point it is made says so; refusing at the push would not explain why.
export LASTLIGHT_WORKSPACE_REGISTRY=$TMP/registry
mkdir -p "$LASTLIGHT_WORKSPACE_REGISTRY"
printf '%s\n%s\n' "$(cd "$REPO" && pwd -P)" "/some/real/repo" \
  > "$LASTLIGHT_WORKSPACE_REGISTRY/1"
expect refuse "recording inside a work workspace"
rm -rf "$LASTLIGHT_WORKSPACE_REGISTRY"
printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
