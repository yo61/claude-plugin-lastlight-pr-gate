#!/usr/bin/env bash
# Test suite for lastlight-sandbox.sh — the isolation policy.
#
# The header of that file claims four controls were verified by hand. A claim
# verified once and never re-run is a comment, not a test: a later edit that
# drops `denyRead` or nests a field wrongly would leave the claim in place and
# the confinement gone. These pin the SHAPE of the policy so that regresses
# loudly, and exercise the workspace construction for real.
#
# What is deliberately NOT here: the end-to-end containment behaviour (a write
# outside the workspace being refused by the OS). That needs a live `claude -p`
# session per case — too slow and too dependent on a working API for CI. The
# runner instead proves containment at RUN time via sandbox_verify(), which is
# the check that actually matters, and this suite covers the policy that check
# depends on.
#
# Run: bash tests/lastlight-sandbox.test.sh
set -uo pipefail
SANDBOX="${SANDBOX:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lastlight-sandbox.sh}"
# Resolve to absolute even though nothing here cd's before sourcing. Twice now a
# relative path in a sibling suite has broken the prek hook while CI stayed
# green, because prek passes a relative path and CI an absolute one. Cheap
# insurance against the third time.
SANDBOX=$(cd "$(dirname "$SANDBOX")" && printf '%s/%s' "$PWD" "$(basename "$SANDBOX")")
pass=0
fail=0

die() {
  printf 'die: %s\n' "$1" >&2
  return 1
}
# shellcheck disable=SC1090  # path resolved at runtime from $SANDBOX
source "$SANDBOX"

ok() { # ok <condition-description> <actual> <expected>
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$3" "$2"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
POLICY=$(sandbox_settings_json "$TMP/ws")

echo "--- the policy asserts every control the header claims ---"
ok "sandbox enabled" "$(jq -r '.sandbox.enabled' <<< "$POLICY")" "true"
ok "fails rather than degrades" "$(jq -r '.sandbox.failIfUnavailable' <<< "$POLICY")" "true"
ok "bash auto-allowed (probes)" "$(jq -r '.sandbox.autoAllowBashIfSandboxed' <<< "$POLICY")" "true"
ok "hooks disabled" "$(jq -r '.disableAllHooks' <<< "$POLICY")" "true"
ok "writes confined to the ws" "$(jq -r '.sandbox.filesystem.allowWrite | join(",")' <<< "$POLICY")" "$TMP/ws"

echo "--- credential stores are denied for reading ---"
for p in .ssh .aws .gnupg .netrc .config/gh .claude/.credentials.json; do
  ok "denyRead covers ~/$p" \
    "$(jq -r --arg p "$HOME/$p" '.sandbox.filesystem.denyRead | index($p) != null' <<< "$POLICY")" "true"
done

echo "--- egress is the control that closes exfiltration ---"
ok "API reachable" "$(jq -r '.sandbox.network.allowedDomains | index("api.anthropic.com") != null' <<< "$POLICY")" "true"
# Package registries must NOT be reachable by default: installing dependencies
# is a probe affordance opted into per-run, and every host widens the only path
# exfiltration has left.
for host in registry.npmjs.org pypi.org github.com example.com; do
  ok "$host NOT reachable by default" \
    "$(jq -r --arg h "$host" '.sandbox.network.allowedDomains | index($h) != null' <<< "$POLICY")" "false"
done

echo "--- opt-in egress widens it, and only when asked ---"
WIDE=$(LASTLIGHT_REVIEW_EGRESS=registry.npmjs.org sandbox_settings_json "$TMP/ws")
ok "opt-in host present" \
  "$(jq -r '.sandbox.network.allowedDomains | index("registry.npmjs.org") != null' <<< "$WIDE")" "true"
ok "API still present" \
  "$(jq -r '.sandbox.network.allowedDomains | index("api.anthropic.com") != null' <<< "$WIDE")" "true"

echo "--- the workspace is a real, independent copy ---"
REPO=$TMP/src
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo original > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm "feat: base"
SHA=$(git -C "$REPO" rev-parse HEAD)
WS=$(cd "$REPO" && sandbox_make_workspace "$REPO" "$SHA")

ok "checked out at the right sha" "$(git -C "$WS" rev-parse HEAD)" "$SHA"
ok "content present" "$(cat "$WS/f.txt")" "original"
ok "has its own .git" "$([[ -d "$WS/.git" ]] && echo yes || echo no)" "yes"
# --no-hardlinks is load-bearing: a hardlinked object store means a process that
# can write in the clone can corrupt the ORIGINAL repository through the shared
# inode. Compare an object's link count -- 1 means it is not shared.
obj=$(find "$WS/.git/objects" -type f -name '*' ! -path '*/info/*' ! -path '*/pack/*' | head -1)
if [[ -n $obj ]]; then
  ok "objects are NOT hardlinked to the source" "$(stat -f %l "$obj" 2> /dev/null || stat -c %h "$obj")" "1"
else
  # A packed clone has no loose objects; assert the pack is unshared instead.
  pack=$(find "$WS/.git/objects/pack" -name '*.pack' | head -1)
  ok "pack is NOT hardlinked to the source" "$(stat -f %l "$pack" 2> /dev/null || stat -c %h "$pack")" "1"
fi

echo "--- writing in the workspace cannot reach the source ---"
echo tampered > "$WS/f.txt"
ok "source file untouched" "$(cat "$REPO/f.txt")" "original"

echo "--- working-tree workspace carries UNCOMMITTED state a clone cannot ---"
echo modified >> "$REPO/f.txt"   # uncommitted change to a tracked file
echo untracked > "$REPO/new.txt" # untracked, not ignored
printf 'ignored/\n' > "$REPO/.gitignore"
mkdir -p "$REPO/ignored" && echo junk > "$REPO/ignored/big.bin"
git -C "$REPO" add .gitignore && git -C "$REPO" commit -qm "chore: ignore"

WWS=$(cd "$REPO" && sandbox_make_working_workspace "$REPO")
ok "uncommitted change applied" "$(rg -c modified "$WWS/f.txt" 2> /dev/null || echo 0)" "1"
ok "untracked file copied" "$([[ -f $WWS/new.txt ]] && echo yes || echo no)" "yes"
ok "ignored tree NOT copied" "$([[ -d $WWS/ignored ]] && echo copied || echo excluded)" "excluded"
ok "still an independent .git" "$([[ -d $WWS/.git ]] && echo yes || echo no)" "yes"
# The whole point of the mode: a plain clone would have none of the above.
PLAIN=$(cd "$REPO" && sandbox_make_workspace "$REPO" "$(git -C "$REPO" rev-parse HEAD)")
ok "a plain clone lacks it" "$(rg -c modified "$PLAIN/f.txt" 2> /dev/null || echo 0)" "0"

echo "--- sandbox_probe_verdict: inconclusive fails closed ---"
verdict() { sandbox_probe_verdict "$1" "$2" && echo pass || echo fail; }
# The only outcome that may enable probes: the probe ran, attempted the escape,
# and something refused it.
ok "blocked escape, fully accounted for" "$(verdict 0 'ran rc=1')" "pass"
ok "blocked escape, other errno" "$(verdict 0 'ran rc=13')" "pass"
# The regression this function exists for: a probe that never ran leaves the
# canary absent, which is NOT the same as the sandbox having stopped it.
ok "probe never ran (timeout/auth/model)" "$(verdict 0 '')" "fail"
ok "probe ran but never attempted the escape" "$(verdict 0 'ran')" "fail"
ok "report truncated mid-write" "$(verdict 0 'ran rc=')" "fail"
ok "report is not ours" "$(verdict 0 'something else')" "fail"
# A bare status with no claim to have run is not a report about this probe.
ok "status with no report around it" "$(verdict 0 '1')" "fail"
# A write that reports success while leaving no file behind is unexplained.
ok "escape reported as succeeding, no canary" "$(verdict 0 'ran rc=0')" "fail"
# Containment failure outranks every account the probe gives of itself.
ok "canary escaped, probe claims refusal" "$(verdict 1 'ran rc=1')" "fail"
ok "canary escaped, probe silent" "$(verdict 1 '')" "fail"

echo "--- untracked files are copied faithfully, not approximately ---"
mkdir -p "$REPO/nested/deep"
echo nested > "$REPO/nested/deep/file.txt"
echo spaced > "$REPO/a file with spaces.txt"
ln -sfn /etc/hosts "$REPO/dangling-link"
WWS2=$(sandbox_make_working_workspace "$REPO")
ok "untracked file in a new subdirectory" \
  "$([[ -f "$WWS2/nested/deep/file.txt" ]] && echo yes || echo no)" "yes"
ok "untracked filename containing spaces" \
  "$([[ -f "$WWS2/a file with spaces.txt" ]] && echo yes || echo no)" "yes"
# A symlink copied as its target drags a file from outside the repo INTO the
# workspace, which is the opposite of isolating the review.
ok "untracked symlink stays a symlink" \
  "$([[ -L "$WWS2/dangling-link" ]] && echo yes || echo no)" "yes"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
