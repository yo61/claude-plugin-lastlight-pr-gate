#!/usr/bin/env bash
# Test suite for lastlight-work-sandbox.sh — confining the work, not just the
# review.
#
# The policy functions and the containment verdict are tested directly, without
# a model call. That is deliberate: the verdict is where a sandbox fails open,
# and a check that costs money per assertion is a check that stops being run.
set -uo pipefail

pass=0
fail=0

ok() {
  local what=$1 got=$2 want=$3
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$what" "$want" "$got"
  fi
}

WORK="${WORK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lastlight-work-sandbox.sh}"
# Resolve to an absolute path up front. Several cases below cd into scratch
# repositories, and a relative path would silently stop resolving there --
# every assertion would then measure the harness rather than the script.
WORK=$(cd "$(dirname "$WORK")" && printf '%s/%s' "$PWD" "$(basename "$WORK")")
[[ -f $WORK ]] || {
  printf 'no script at %s\n' "$WORK" >&2
  exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LASTLIGHT_WORK_ROOT="$TMP/work"

# shellcheck disable=SC1090  # path resolved at runtime from $WORK
source "$WORK"
# Sourcing ran the script's own `set -euo pipefail` IN THIS SHELL, which turned
# on errexit here. The first failing assertion then killed the run before the
# summary, so a failure looked like the suite stopping rather than failing.
# Declare the option this suite wants instead of inheriting one.
set +e

# ── the containment verdict ──────────────────────────────────────────────
echo "--- work_probe_verdict: inconclusive fails closed ---"
verdict() { work_probe_verdict "$1" "$2" "$3" && echo pass || echo fail; }

# The only outcome that may open a session: nothing escaped by either route,
# and the probe gave a complete account of having tried.
ok "both layers held, fully accounted for" "$(verdict 0 0 'ran rc=1')" "pass"
ok "both held, other errno" "$(verdict 0 0 'ran rc=13')" "pass"

# A spawned process reaching outside the workspace is the classic escape.
ok "bash escaped" "$(verdict 1 0 'ran rc=1')" "fail"
# ...and so is a file-editing tool reaching the real repository, which the OS
# sandbox does NOT cover. Verified directly: with only the filesystem sandbox
# in force, the Write tool created a file outside the workspace.
ok "edit reached the real repo" "$(verdict 0 1 'ran rc=1')" "fail"
ok "both escaped" "$(verdict 1 1 'ran rc=1')" "fail"

# The fail-open this exists to prevent: a probe that never ran leaves both
# canaries absent, which is not the same as a policy that held.
ok "probe never ran" "$(verdict 0 0 '')" "fail"
ok "ran but never attempted" "$(verdict 0 0 'ran')" "fail"
ok "report truncated mid-write" "$(verdict 0 0 'ran rc=')" "fail"
ok "report is not ours" "$(verdict 0 0 'unrelated text')" "fail"
ok "status with no report around it" "$(verdict 0 0 '1')" "fail"
# A write reporting success while leaving no file behind is unexplained.
ok "escape reported as succeeding" "$(verdict 0 0 'ran rc=0')" "fail"

# ── the policy document ──────────────────────────────────────────────────
echo "--- work_settings_json: both layers, spelled the way they are read ---"
POLICY=$(work_settings_json /ws /repo)

ok "bash is confined to the workspace" \
  "$(jq -r '.sandbox.filesystem.allowWrite | index("/ws") != null' <<< "$POLICY")" "true"
# Builds, package managers and test runners are unusable without a temp dir.
# A deliberate widening of the review policy: a temp file is not the repo.
ok "temp is writable for spawned processes" \
  "$(jq -r '.sandbox.filesystem.allowWrite | length' <<< "$POLICY")" "2"
ok "the sandbox must actually engage" \
  "$(jq -r '.sandbox.failIfUnavailable' <<< "$POLICY")" "true"
ok "secrets are unreadable" \
  "$(jq -r '.sandbox.filesystem.denyRead | length > 0' <<< "$POLICY")" "true"

# THE RULE SPELLING. Both of these fail silently when wrong, which is why they
# are asserted rather than trusted:
#   - `Write(...)` rules are not consulted by file permission checks at all;
#     `Edit(...)` rules cover every file-editing tool. Claude Code says so when
#     given the wrong one, but only in a message nothing reads.
#   - an absolute path needs a DOUBLED slash. `Edit(/ws/**)` matches nothing,
#     denies nothing, and looks exactly like a rule that works.
ok "editing is allowed in the workspace" \
  "$(jq -r '.permissions.allow | index("Edit(//ws/**)") != null' <<< "$POLICY")" "true"
ok "editing the real repo is denied" \
  "$(jq -r '.permissions.deny | index("Edit(//repo/**)") != null' <<< "$POLICY")" "true"
ok "no rule uses the Write() spelling" \
  "$(jq -r '[.permissions[][] | select(startswith("Write("))] | length' <<< "$POLICY")" "0"
ok "every rule uses the doubled slash" \
  "$(jq -r '[.permissions[][] | select(test("^Edit\\(//[^/]") | not)] | length' <<< "$POLICY")" "0"

# Deny beats allow and beats an interactive approval, so these stay unreachable
# even if someone clicks yes on a prompt.
# EVERY path the read policy protects, not a hand-picked few. These lists were
# maintained separately once and drifted -- the read policy named nine stores
# and the edit policy five, losing .netrc, .npmrc, .pypirc and
# .docker/config.json, all files a session could rewrite to point a package
# manager wherever it liked. Deriving the expectation from the same source is
# what stops the test drifting with it.
while IFS= read -r secret; do
  ok "$secret cannot be edited" \
    "$(jq -r --arg s "$secret" '[.permissions.deny[] | select(. == "Edit(/" + $s + ")" or . == "Edit(/" + $s + "/**)")] | length' <<< "$POLICY")" "2"
done < <(edit_denied_paths)

# A session that can edit ~/.claude/hooks can switch off the guard watching it.
ok "the agent's own configuration is denied" \
  "$(jq -r --arg h "$HOME" '[.permissions.deny[] | select(. == "Edit(/" + $h + "/.claude/**)")] | length' <<< "$POLICY")" "1"

echo "--- work_allowed_domains ---"
ok "the model endpoint is reachable" \
  "$(work_allowed_domains | grep -c '^api\.anthropic\.com$')" "1"
ok "the forge is reachable, because work fetches" \
  "$(work_allowed_domains | grep -c '^github\.com$')" "1"
ok "extra egress is opt-in" \
  "$(LASTLIGHT_WORK_EGRESS=example.com,example.org work_allowed_domains | grep -c '^example\.org$')" "1"

# ── slots ────────────────────────────────────────────────────────────────
echo "--- slot_for ---"
ok "one slot per repo and branch" \
  "$(slot_for /a/b/myrepo feat/x)" "$LASTLIGHT_WORK_ROOT/myrepo/feat/x"

echo "--- resolve ---"
mkdir -p "$TMP/real/inner"
ln -s "$TMP/real" "$TMP/link"
# A permission rule is matched against the canonical path the tool reports, so
# a rule written from an unresolved one protects nothing.
ok "a symlinked directory resolves to its target" \
  "$(resolve "$TMP/link/inner")" "$(cd "$TMP/real/inner" && pwd -P)"
ok "a path that does not exist yet still resolves its parent" \
  "$(resolve "$TMP/link/inner/new.txt")" "$(cd "$TMP/real/inner" && pwd -P)/new.txt"

# ── workspace and landing ────────────────────────────────────────────────
echo "--- make_workspace ---"
REPO=$TMP/repo
git init --quiet -b main "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
echo one > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit --quiet -m "one"
git -C "$REPO" checkout --quiet -b feat/x
echo two > "$REPO/file.txt"
git -C "$REPO" commit --quiet -am "two"
git -C "$REPO" checkout --quiet main

WS=$(slot_for "$REPO" feat/x)/repo
make_workspace "$REPO" feat/x "$WS"
git -C "$WS" config user.email t@example.com
git -C "$WS" config user.name Test
ok "the workspace is on the requested branch" \
  "$(git -C "$WS" symbolic-ref --short HEAD)" "feat/x"
ok "it carries that branch's work" "$(cat "$WS/file.txt")" "two"
# A local clone hardlinks its object files by default, so a write in the
# workspace could truncate an object in the real repository -- the one thing
# the isolation exists to prevent.
obj=$(find "$WS/.git/objects" -type f | head -1)
ok "objects are NOT hardlinked to the source" \
  "$(stat -f %l "$obj" 2> /dev/null || stat -c %h "$obj")" "1"

WS2=$(slot_for "$REPO" feat/brand-new)/repo
make_workspace "$REPO" feat/brand-new "$WS2"
git -C "$WS2" config user.email t@example.com
git -C "$WS2" config user.name Test
ok "an unknown branch is created, not an error" \
  "$(git -C "$WS2" symbolic-ref --short HEAD)" "feat/brand-new"

echo "--- land ---"
# Work done in the workspace, then landed.
echo three > "$WS/file.txt"
git -C "$WS" commit --quiet -am "three"
landed=$(cd "$REPO" && "$WORK" land -b feat/x 2>&1)
ok "landing reports the move" "$(grep -c 'landed feat/x' <<< "$landed")" "1"
ok "the branch moved in the real repository" \
  "$(git -C "$REPO" log -1 --format=%s feat/x)" "three"
ok "the working tree was not switched under the user" \
  "$(git -C "$REPO" symbolic-ref --short HEAD)" "main"
# Landing moves code onto a branch; it does not make that code pushable. The
# push gate is what does, and its markers live where the sandbox cannot write.
ok "landing says the work is not yet pushable" \
  "$(grep -c 'NOT pushable' <<< "$landed")" "1"

again=$(cd "$REPO" && "$WORK" land -b feat/x 2>&1)
ok "landing twice is a no-op, not an error" "$(grep -c 'nothing to land' <<< "$again")" "1"

# A diverged branch is a thing for a person to look at, not for a script to
# resolve by overwriting one side of it.
git -C "$REPO" checkout --quiet feat/x
echo divergent > "$REPO/file.txt"
git -C "$REPO" commit --quiet -am "divergent"
git -C "$REPO" checkout --quiet main
echo four > "$WS/file.txt"
git -C "$WS" commit --quiet -am "four"
out=$(cd "$REPO" && "$WORK" land -b feat/x 2>&1)
rc=$?
ok "a diverged branch refuses to land" "$rc" "1"
ok "...and says why" "$(grep -c 'diverged' <<< "$out")" "1"
ok "...leaving the repository's branch untouched" \
  "$(git -C "$REPO" log -1 --format=%s feat/x)" "divergent"

# One place the work lives. A dirty workspace means the branch does not yet
# describe the state, so landing it would quietly drop the difference.
echo uncommitted > "$WS2/file.txt"
out=$(cd "$REPO" && "$WORK" land -b feat/brand-new 2>&1)
rc=$?
ok "a dirty workspace refuses to land" "$rc" "1"
ok "...and says to commit or stash" "$(grep -c 'Commit or stash' <<< "$out")" "1"

out=$(cd "$REPO" && "$WORK" land -b no/such/branch 2>&1)
ok "landing an unknown branch explains how to start one" \
  "$(grep -c 'start one with' <<< "$out")" "1"

echo "--- unknown input ---"
out=$("$WORK" bogus 2>&1)
ok "an unknown command is rejected" "$(grep -c 'unknown command' <<< "$out")" "1"
out=$(cd "$REPO" && "$WORK" land --bogus 2>&1)
ok "an unknown option is rejected" "$(grep -c 'unknown option' <<< "$out")" "1"
ok "--help prints the usage" "$("$WORK" --help | grep -c 'Do the WORK in a sandbox')" "1"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
