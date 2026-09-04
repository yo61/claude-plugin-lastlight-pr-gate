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
RECORD="${RECORD:-$HOME/.claude/hooks/lastlight-review-record.sh}"
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

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
