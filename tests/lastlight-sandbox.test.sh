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
ok "writes include the workspace" \
  "$(jq -r --arg w "$TMP/ws" '.sandbox.filesystem.allowWrite | index($w) != null' <<< "$POLICY")" "true"
# ...and a scratch directory, because the reviewer is meant to run probes and
# nearly every package manager, build tool and test runner stages through
# $TMPDIR. Without it `mktemp -d` fails while the runner still says "probes
# enabled" -- observed from inside a review running under this policy.
ok "...and a scratch directory for probes" \
  "$(jq -r '.sandbox.filesystem.allowWrite | length' <<< "$POLICY")" "2"
ok "...and nothing else" \
  "$(jq -r --arg w "$TMP/ws" --arg t "$(cd "${TMPDIR:-/tmp}" && pwd -P)" \
    '[.sandbox.filesystem.allowWrite[] | select(. != $w and . != $t)] | length' <<< "$POLICY")" "0"

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
# Three outcomes: a proven refusal, a write that got out, and a probe that
# could not say. The last two both refuse to proceed but mean opposite things,
# and the caller reports them differently.
verdict() {
  local rc=0
  sandbox_probe_verdict "$1" "$2" || rc=$?
  case $rc in
    0) echo pass ;;
    2) echo inconclusive ;;
    *) echo escaped ;;
  esac
}
# The only outcome that may enable probes: the probe ran, attempted the escape,
# and something refused it.
ok "blocked escape, fully accounted for" "$(verdict 0 'ran rc=1')" "pass"
ok "blocked escape, other errno" "$(verdict 0 'ran rc=13')" "pass"
# The regression this function exists for: a probe that never ran leaves the
# canary absent, which is NOT the same as the sandbox having stopped it.
ok "probe never ran (timeout/auth/model)" "$(verdict 0 '')" "inconclusive"
ok "probe ran but never attempted the escape" "$(verdict 0 'ran')" "inconclusive"
ok "report truncated mid-write" "$(verdict 0 'ran rc=')" "inconclusive"
ok "report is not ours" "$(verdict 0 'something else')" "inconclusive"
# A bare status with no claim to have run is not a report about this probe.
ok "status with no report around it" "$(verdict 0 '1')" "inconclusive"
# A write that reports success while leaving no file behind is unexplained.
ok "escape reported as succeeding, no canary" "$(verdict 0 'ran rc=0')" "inconclusive"
# Containment failure outranks every account the probe gives of itself.
ok "canary escaped, probe claims refusal" "$(verdict 1 'ran rc=1')" "escaped"
ok "canary escaped, probe silent" "$(verdict 1 '')" "escaped"

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

echo "--- sandbox_escape_canary: a probe target that measures something ---"
CANARY=$(sandbox_escape_canary)
# `$(mktemp -u)/name` prints a name without creating the parent, so the write
# failed with ENOENT whether or not a sandbox was engaged -- and a probe that
# always fails is a probe that always reports containment.
ok "the canary's parent directory exists" \
  "$([[ -d $(dirname "$CANARY") ]] && echo yes || echo no)" "yes"
ok "the canary itself does not exist yet" \
  "$([[ -e $CANARY ]] && echo yes || echo no)" "no"
# A canary under a directory the policy grants would be written by a correctly
# confined session and misread as an escape.
ok "the canary is not under the temp dir the work policy allows" \
  "$(case $CANARY in "${TMPDIR:-/tmp}"*) echo under ;; *) echo outside ;; esac)" "outside"

echo "--- sandbox_denied_reads: the stores that actually hold tokens ---"
denied() { sandbox_denied_reads | grep -cx "$1"; }
# git's own HTTPS credential store. The work sandbox opens egress to github.com
# so builds can fetch, which is the route a token read from here would leave by.
ok "git credential store is unreadable" "$(denied "$HOME/.git-credentials")" "1"
ok "...and its XDG location too" \
  "$(denied "${XDG_CONFIG_HOME:-$HOME/.config}/git/credentials")" "1"
ok "netrc, which serves the same purpose, is unreadable" "$(denied "$HOME/.netrc")" "1"
ok "ssh keys are unreadable" "$(denied "$HOME/.ssh")" "1"
ok "every entry is absolute" \
  "$(sandbox_denied_reads | grep -cv '^/')" "0"

echo "--- read_deny_rules: the Read tool needs its own rules ---"
REVIEW_POLICY=$(sandbox_settings_json /ws)
# sandbox.filesystem.denyRead confines spawned processes only. Verified: with
# denyRead naming the directory, a `cat` under Bash was refused while the Read
# tool returned the file's contents in the same session. The review sandbox
# shipped with no permissions block at all, and the reviewed diff is untrusted
# by construction -- a prompt injection could have it read a credential and copy
# it into findings.json, the one file carried back out of the workspace.
ok "the review policy denies reads by rule, not only by sandbox" \
  "$(jq -r '.permissions.deny | length > 0' <<< "$REVIEW_POLICY")" "true"
while IFS= read -r secret; do
  ok "$secret cannot be Read" \
    "$(jq -r --arg s "$secret" '[.permissions.deny[] | select(. == "Read(/" + $s + ")" or . == "Read(/" + $s + "/**)")] | length' <<< "$REVIEW_POLICY")" "2"
done < <(sandbox_denied_reads)
ok "every review rule uses the doubled slash" \
  "$(jq -r '[.permissions.deny[] | select(test("^Read\\(//[^/]") | not)] | length' <<< "$REVIEW_POLICY")" "0"

echo "--- reads are scoped, not enumerated ---"
# A curated denylist protects what was thought of. The reviewed diff is a
# prompt-injection surface, and the interesting targets are not only credential
# files -- a sibling repository's .env, a shell history, another session's
# transcript. Anything read leaves through findings.json, which is carried out
# of the workspace and posted as a PR comment with no human in between.
ok "the whole home directory is denied" \
  "$(jq -r --arg h "$HOME" '[.permissions.deny[] | select(. == "Read(/" + $h + "/**)")] | length' <<< "$REVIEW_POLICY")" "1"
ok "...including the directory itself" \
  "$(jq -r --arg h "$HOME" '[.permissions.deny[] | select(. == "Read(/" + $h + ")")] | length' <<< "$REVIEW_POLICY")" "1"
# The workspace lives under $TMPDIR, outside $HOME, so this costs the reviewer
# nothing -- provided everything it needs is staged inside.
ok "the workspace is not caught by that" \
  "$(case "$TMP/ws" in "$HOME"/*) echo inside ;; *) echo outside ;; esac)" "outside"

echo "--- egress overrides stay in their own scope ---"
ok "the review override reaches the review list" \
  "$(LASTLIGHT_REVIEW_EGRESS=probe.example.com sandbox_allowed_domains | grep -c '^probe\.example\.com$')" "1"
ok "...and not the base every sandbox shares" \
  "$(LASTLIGHT_REVIEW_EGRESS=probe.example.com sandbox_base_domains | grep -c '^probe\.example\.com$')" "0"
ok "the base still carries the model endpoint" \
  "$(sandbox_base_domains | grep -c '^api\.anthropic\.com$')" "1"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
