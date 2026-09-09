#!/usr/bin/env bash
# shellcheck disable=SC2154  # WORK_ROOT is assigned by the script this suite
# sources, and asserting on the policy it produces is the point.
#
# Test suite for lastlight-work-sandbox.sh — confining the work, not just the
# review.
#
# The policy functions and the containment verdict are tested directly, without
# a model call. That is deliberate: the verdict is where a sandbox fails open,
# and a check that costs money per assertion is a check that stops being run.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
clear_inherited_config
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
# escaped_bash, escaped_edit, report, edit_worked
verdict() { work_probe_verdict "$1" "$2" "$3" "${4:-1}" && echo pass || echo fail; }

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

# ...and the other direction, which nothing tested for three rounds: a policy
# can be wrong by forbidding what it is supposed to ALLOW. When the work root
# sat under a denied tree, every edit inside the workspace was refused, the
# probe never tried one, and the session opened "verified" and broke on its
# first edit.
ok "editing inside the workspace was refused" "$(verdict 0 0 'ran rc=1' 0)" "fail"
ok "everything held and editing works" "$(verdict 0 0 'ran rc=1' 1)" "pass"

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
  "$(jq -r '[.permissions[][] | select(test("^(Edit|Read)\\(//[^/]") | not)] | length' <<< "$POLICY")" "0"
# The OS sandbox reaches neither tool: denyRead stops a spawned process, while
# the Read tool is native to the CLI and walks past it. Verified directly -- a
# `cat` under Bash was refused while Read returned the same file's contents.
#
# Reads of the real repository are deliberately NOT denied: it holds the same
# code the session is working on, so reading it leaks nothing. What must not
# happen is writing to it, which the Edit rules above cover.
while IFS= read -r secret; do
  ok "$secret cannot be read" \
    "$(jq -r --arg s "$secret" '[.permissions.deny[] | select(. == "Read(/" + $s + ")" or . == "Read(/" + $s + "/**)")] | length' <<< "$POLICY")" "2"
done < <(edit_denied_paths)

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
# The review's override must not reach here. A host opted into for a review
# probe was silently reachable from a work session too -- the one that also
# holds Write and Edit, and whose stated threat is a poisoned dependency.
ok "the review's egress override does NOT leak in" \
  "$(LASTLIGHT_REVIEW_EGRESS=exfil.example.com work_allowed_domains | grep -c '^exfil\.example\.com$')" "0"

# ── slots ────────────────────────────────────────────────────────────────
echo "--- slot_for ---"
ok "the slot is under the work root, named for the repo" \
  "$(slot_for /a/b/myrepo feat/x)" \
  "$LASTLIGHT_WORK_ROOT/$(repo_key /a/b/myrepo)/feat/x"
ok "the same repo always resolves to the same slot" \
  "$(slot_for /a/b/myrepo feat/x)" "$(slot_for /a/b/myrepo feat/x)"
# Two unrelated projects called `api` shared a slot, so `start` in one opened
# the other's clone and `land` fetched an unrelated history into the wrong
# repository.
ok "repos sharing a basename do NOT share a slot" \
  "$([[ $(slot_for /projA/api main) == "$(slot_for /projB/api main)" ]] && echo same || echo distinct)" \
  "distinct"
ok "...and the basename is still there to read" \
  "$(basename "$(dirname "$(slot_for /projA/api main)")" | cut -d- -f1)" "api"

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
  "$(link_count "$obj")" "1"

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

echo "--- the workspace must not sit inside its own deny list ---"
# ~/.claude is denied whole so a session cannot edit the hooks watching it. The
# default work root used to live there, making every workspace a subtree of its
# own deny rule -- and deny beats allow regardless of specificity, so the Edit
# tool was refused throughout the session's own workspace.
ok "a workspace under a denied tree is caught" \
  "$(workspace_is_denied "$HOME/.claude/work/repo/branch/repo" && echo denied || echo ok)" "denied"
ok "a workspace under the real default is not" \
  "$(workspace_is_denied "$HOME/.lastlight/work/repo/branch/repo" && echo denied || echo ok)" "ok"
ok "an exact denied path is caught, not just a child" \
  "$(workspace_is_denied "$HOME/.ssh" && echo denied || echo ok)" "denied"
# The regression itself: whatever the default becomes, it must be somewhere a
# session can actually edit.
# shellcheck disable=SC2016  # deliberate: these must expand in the CHILD shell,
# which is the whole point -- it re-sources the script with the variable unset
# so the SHIPPED default is what gets tested, not the one this suite exports.
ok "the shipped default work root is editable" \
  "$(env -u LASTLIGHT_WORK_ROOT bash -c 'source "$1"; workspace_is_denied "$(slot_for /a/b/repo main)/repo" && echo denied || echo ok' _ "$WORK")" "ok"

echo "--- land refuses a workspace belonging to another repository ---"
OTHER=$TMP/otherrepo
git init --quiet -b main "$OTHER"
git -C "$OTHER" config user.email t@example.com
git -C "$OTHER" config user.name Test
echo other > "$OTHER/file.txt"
git -C "$OTHER" add file.txt
git -C "$OTHER" commit --quiet -m "other"
git -C "$OTHER" checkout --quiet -b squatter
# Put a clone of the WRONG repository where this repo's workspace would live.
SQUAT=$(slot_for "$REPO" squatter)/repo
mkdir -p "$(dirname "$SQUAT")"
git clone --quiet --no-hardlinks --branch squatter "$OTHER" "$SQUAT"
out=$(cd "$REPO" && "$WORK" land -b squatter 2>&1)
rc=$?
ok "landing a foreign workspace fails" "$rc" "1"
ok "...and says whose it actually is" "$(grep -c 'not a clone of this repository' <<< "$out")" "1"
ok "...leaving no such branch behind" \
  "$(git -C "$REPO" show-ref --verify --quiet refs/heads/squatter && echo created || echo absent)" "absent"

echo "--- land onto the branch the repository is sitting on ---"
# The natural flow: start on the branch you are already on, work, land back.
# git refuses to fetch into a checked-out branch, and that refusal used to be
# reported as history divergence -- sending the reader to fix a conflict that
# did not exist. The old suite hid this by switching away first.
git -C "$REPO" checkout --quiet -b feat/onbranch
git -C "$REPO" commit --quiet --allow-empty -m "base for onbranch"
WS3=$(slot_for "$REPO" feat/onbranch)/repo
make_workspace "$REPO" feat/onbranch "$WS3"
git -C "$WS3" config user.email t@example.com
git -C "$WS3" config user.name Test
echo landed > "$WS3/file.txt"
git -C "$WS3" commit --quiet -am "work done in the sandbox"
out=$(cd "$REPO" && "$WORK" land -b feat/onbranch 2>&1)
rc=$?
ok "landing onto the checked-out branch succeeds" "$rc" "0"
ok "...and does not blame divergence" "$(grep -c diverged <<< "$out")" "0"
ok "...the branch actually moved" \
  "$(git -C "$REPO" log -1 --format=%s feat/onbranch)" "work done in the sandbox"
# ff-only into a live working tree, so the files must be updated too, not just
# the ref -- a ref moved out from under the tree would be worse than an error.
ok "...and the working tree matches it" "$(cat "$REPO/file.txt")" "landed"

# A dirty tree must not be fast-forwarded over.
echo scribble > "$REPO/file.txt"
echo more > "$WS3/file.txt"
git -C "$WS3" commit --quiet -am "second"
out=$(cd "$REPO" && "$WORK" land -b feat/onbranch 2>&1)
rc=$?
ok "a dirty repository refuses to land" "$rc" "1"
ok "...and says to commit or stash" "$(grep -c 'Commit or stash' <<< "$out")" "1"
git -C "$REPO" checkout --quiet -- file.txt
git -C "$REPO" checkout --quiet main

echo "--- \$HOME's other trees are denied, one entry at a time ---"
# The named list covers credential stores. It said nothing about a sibling
# project, a shell history or another session's transcript -- all readable by
# the Read tool, and a work session can write what it reads into a tracked file
# that `land` then fast-forwards into the real repository.
#
# A blanket Read(\$HOME/**) is not available: the workspace lives under \$HOME by
# default and a deny beats an allow -- verified, an explicit allow on the
# workspace did NOT reinstate it. Hence the enumeration.

# Against a CONTROLLED $HOME, not this one. Asserting on whatever happens to be
# on disk cannot see the two decisions that matter: `~/.lastlight` may not
# exist yet, so "the work root is excluded" passes whether or not the code
# excludes it, and every hidden entry that does exist is also in the named
# credential list, so "dotfiles are enumerated" passes either way. Both were
# verified to survive a mutation before this replaced them.
FAKE=$(mktemp -d)
MYWS=$FAKE/.lastlight/work/repoA-1111/main/repo
OTHERWS=$FAKE/.lastlight/work/repoB-2222/main/repo
mkdir -p "$MYWS" "$OTHERWS" "$FAKE/code" "$FAKE/.hidden-sibling" "$FAKE/..dotdot-sibling"
fake_siblings() {
  HOME="$FAKE" LASTLIGHT_WORK_ROOT="$FAKE/.lastlight/work" \
    bash -c 'source "$1" 2>/dev/null; home_siblings_denied "" "$2"' _ "$WORK" "$MYWS"
}
ok "this session's own workspace is left out" \
  "$(fake_siblings | grep -cx "$MYWS")" "0"
# The work root is SHARED -- `list` exists because several workspaces are open
# at once -- so exempting its whole top-level component left every other
# repository's and branch's clone readable from this session.
ok "another repository's workspace IS denied" \
  "$(fake_siblings | grep -c "repoB-2222")" "1"
ok "a visible sibling is enumerated" \
  "$(fake_siblings | grep -cx "$FAKE/code")" "1"
ok "a HIDDEN sibling is enumerated too" \
  "$(fake_siblings | grep -cx "$FAKE/.hidden-sibling")" "1"
# Two leading dots is a legal directory name that neither `*` nor `.[!.]*`
# matches, so such a tree was left out of the deny list altogether.
ok "a sibling starting with two dots is enumerated" \
  "$(fake_siblings | grep -cx "$FAKE/..dotdot-sibling")" "1"
# ...and the directory entries themselves never are.
ok "neither . nor .. is enumerated" \
  "$(fake_siblings | grep -cE '/\.\.?$')" "0"

# ...and under the oldest bash available, which is where it matters. bash 5.2
# added GLOBSKIPDOTS, so `..*` never yields `..` there and a suite running on
# it cannot tell the correct glob from the greedy one; the macOS system bash
# is 3.2, where it can. The hook runs under whichever bash `env bash` finds.
#
# Run UNCONDITIONALLY, on /bin/bash when there is one. A case that runs only
# on some machines makes the suite's own count vary by machine, and this repo
# checks that count -- CI reported one fewer assertion than this machine and
# failed on the mismatch, not on anything being wrong.
OLDSH=/bin/bash
[[ -x $OLDSH ]] || OLDSH=$(command -v bash)
# shellcheck disable=SC2016  # $1 and $2 belong to the inner shell, not this one
ok "nor under the oldest bash to hand" \
  "$(HOME="$FAKE" LASTLIGHT_WORK_ROOT="$FAKE/.lastlight/work" \
    "$OLDSH" -c 'source "$1" 2>/dev/null; home_siblings_denied "" "$2"' _ "$WORK" "$MYWS" \
    | grep -cE '/\.\.?$')" "0"
# ...and the chain down to the kept workspace is not denied, or the session
# could not reach its own tree.
ok "the chain to the workspace is open" \
  "$(fake_siblings | grep -cx "$FAKE/.lastlight")" "0"

# A workspace outside $HOME needs no exemption: nothing under $HOME leads to
# it, so the enumeration simply never reaches it.
ok "an outside workspace changes nothing under \$HOME" \
  "$(HOME="$FAKE" bash -c 'source "$1" 2>/dev/null; home_siblings_denied "" /tmp/elsewhere/repo' _ "$WORK" | grep -cx "$FAKE/code")" "1"
rm -rf "$FAKE"

# Against a controlled $HOME again, and with a repo nested inside it the way
# they usually are. Asserting on `$HOME/code` from the real machine only passes
# where a `code` directory happens to exist -- it does not on a runner, and
# `home_siblings_denied` emits only what is on disk.
FAKE2=$(mktemp -d)
mkdir -p "$FAKE2/.lastlight" "$FAKE2/code/myrepo" "$FAKE2/code/otherproject" "$FAKE2/docs"
fake_policy() {
  HOME="$FAKE2" LASTLIGHT_WORK_ROOT="$FAKE2/.lastlight/work" \
    bash -c 'source "$1" 2>/dev/null; work_settings_json "$2" "$3"' \
    _ "$WORK" "$FAKE2/.lastlight/work/slot/repo" "$FAKE2/code/myrepo"
}
POLICY=$(fake_policy)
denied_rule() {
  jq -r --arg r "$1" '.permissions.deny | index($r) != null' <<< "$POLICY"
}

ok "another project under the same parent is denied" \
  "$(denied_rule "Read(/$FAKE2/code/otherproject/**)")" "true"
ok "...and cannot be edited either" \
  "$(denied_rule "Edit(/$FAKE2/code/otherproject/**)")" "true"
ok "an unrelated tree is denied" \
  "$(denied_rule "Read(/$FAKE2/docs/**)")" "true"

# The repository itself, and the chain down to it, stay readable. Denying the
# parent wholesale swept the repo in with it -- the function said in its own
# comment that reads of the real repository are allowed while denying them for
# every repo that lives under $HOME, which is the usual place for one.
ok "the repository is NOT denied" \
  "$(denied_rule "Read(/$FAKE2/code/myrepo/**)")" "false"
ok "...nor its parent, which is the way in" \
  "$(denied_rule "Read(/$FAKE2/code/**)")" "false"
ok "the work root's tree is NOT denied" \
  "$(denied_rule "Read(/$FAKE2/.lastlight/**)")" "false"
rm -rf "$FAKE2"

# The OS layer is deliberately NOT enumerated: spawned processes read $HOME
# during ordinary work -- package manager and compiler caches -- and denying
# those breaks the build the session exists to run.
# $FAKE2, not $HOME: the policy under test was built with HOME pointed there,
# so asserting against the real one compares against a path the policy never
# saw.
ok "the OS layer does not enumerate siblings" \
  "$(jq -r --arg h "$FAKE2/code" '.sandbox.filesystem.denyRead | index($h) != null' <<< "$POLICY")" "false"
ok "...but still names the credential stores" \
  "$(jq -r --arg h "$FAKE2/.ssh" '.sandbox.filesystem.denyRead | index($h) != null' <<< "$POLICY")" "true"

# ~/.claude whole, at the OS layer too. It was on the tool layer only, so a
# spawned process could read the hooks and settings watching it -- and this
# sandbox auto-approves Bash, so an ordinary `npm install` running a poisoned
# postinstall script was enough.
ok "the OS layer denies ~/.claude whole" \
  "$(jq -r --arg h "$FAKE2/.claude" '.sandbox.filesystem.denyRead | index($h) != null' <<< "$POLICY")" "true"

# The probe canaries are per-invocation: `list` exists because several
# workspaces are open at once, and a fixed name lets one session's cleanup
# clear the file another session's probe just wrote, moments before it looks.
ok "the read canary carries the pid" \
  "$(work_read_canary | grep -cE '\.[0-9]+$')" "1"

# Overlapping sources must not produce the same rule twice.
ok "rules are not repeated" \
  "$(jq -r '.permissions.deny | (length == (unique | length))' <<< "$POLICY")" "true"

echo "--- the work verdict judges the READ probe too ---"
# The Bash escape tests the OS sandbox and the Write escape tests the Edit
# rules. Neither touches the Read tool, which sees only permissions.deny --
# the mechanism the sibling enumeration lives in.
wv() {
  work_probe_verdict 0 0 "$1" 1 "$2"
  printf "%s" "$?"
}

WTOK=lastlight-work-read-999
ok "refused read is contained" "$(wv 'ran rc=1 read=REFUSED' "$WTOK")" "0"
ok "the token in the report is an escape" "$(wv "ran rc=1 read=$WTOK" "$WTOK")" "1"
ok "no read= at all is not a proof" "$(wv 'ran rc=1' "$WTOK")" "1"
# The status must still parse now that the report continues past it.
ok "the status is read as its own field" "$(wv 'ran rc=2 read=REFUSED' "$WTOK")" "0"
ok "a zero status is still no refusal" "$(wv 'ran rc=0 read=REFUSED' "$WTOK")" "1"
# The canary is named in the policy explicitly: the sibling enumeration is a
# snapshot taken before the probe runs, so a file created later is not in it.
POLICY2=$(work_settings_json "$WORK_ROOT/probe/branch" /tmp/repo)
ok "the read canary is denied by name" \
  "$(jq -r --arg r "Read(/$(work_read_canary))" '.permissions.deny | index($r) != null' <<< "$POLICY2")" "true"

# A tool the probe is not granted is a policy the probe cannot test: it then
# answers "refused" whatever the rules say, and reports containment. That has
# happened twice here, once for Write and once for Read.
ok "the probe is granted Read" \
  "$(work_probe_tools | grep -c Read)" "1"
ok "...and the full expected set" \
  "$(work_probe_tools)" "Bash,Write,Read"

echo "--- the workspace signal lives outside the workspace ---"
# It used to be a file inside the clone git dir, which a session can write with
# Bash or Edit -- so it could delete the signal, forge a marker in its own
# .git, and push without ever landing back for a review. The proof that code
# may leave the sandbox was stored inside the sandbox.
REG=$TMP/registry
export LASTLIGHT_WORKSPACE_REGISTRY=$REG

REG_WS=$TMP/regws/repo
mkdir -p "$REG_WS"
work_registry_add "$REG_WS" "/some/real/repo"

ok "the entry is outside the workspace" \
  "$(work_registry_entry "$REG_WS" | grep -c "^$REG/" || true)" "1"
ok "...and records the workspace" \
  "$(head -1 "$(work_registry_entry "$REG_WS")")" "$REG_WS"
ok "...and the repository it came from" \
  "$(sed -n 2p "$(work_registry_entry "$REG_WS")")" "/some/real/repo"
# Registering twice must not mint a second entry, or `start` on an existing
# workspace would grow the store every time.
work_registry_add "$REG_WS" "/some/real/repo"
ok "registering again is idempotent" "$(find "$REG" -type f | grep -c . || true)" "1"

# Nothing removes a workspace but a person with rm, so entries are pruned when
# the directory they name is gone. A store that only grows stops being useful
# to anything that reads it.
mkdir -p "$TMP/regws2/repo"
work_registry_add "$TMP/regws2/repo" "/some/real/repo"
rm -rf "$TMP/regws2"
work_registry_add "$REG_WS" "/some/real/repo"
ok "a stale entry is pruned" "$(find "$REG" -type f | grep -c . || true)" "1"

ok "removing deregisters it" \
  "$(
    work_registry_remove "$REG_WS"
    find "$REG" -type f | grep -c . || true
  )" "0"

echo "--- and the policy keeps it readable but not writable ---"
work_registry_add "$REG_WS" "/some/real/repo"
REG_POLICY=$(work_settings_json "/some/real/repo" "$REG_WS")
# Readable, because the gate runs INSIDE the session and has to tell a
# workspace from a real repository. It holds paths, not secrets.
ok "the registry is not read-denied" \
  "$(jq -r '.permissions.deny[]' <<< "$REG_POLICY" | grep -c "^Read(/$REG" || true)" "0"
# ...and that has to be measured where the sibling walk can actually reach it.
# Under $TMP it never does, so the keep looked irrelevant: removing it changed
# no assertion until the registry sat inside the HOME being walked.
HOMEREG=$FAKE/.lastlight/workspaces
mkdir -p "$HOMEREG"
home_reg_denied() {
  HOME="$FAKE" LASTLIGHT_WORK_ROOT="$FAKE/.lastlight/work" \
    LASTLIGHT_WORKSPACE_REGISTRY="$HOMEREG" \
    bash -c 'source "$1" 2>/dev/null; home_siblings_denied "" "$2" "$(work_registry_dir)"' \
    _ "$WORK" "$MYWS"
}
ok "a registry inside HOME survives the sibling walk" \
  "$(home_reg_denied | grep -cx "$HOMEREG" || true)" "0"
# ...while an ordinary sibling beside it is still denied, so the keep is doing
# the work rather than the walk having stopped early.
mkdir -p "$FAKE/.lastlight/unrelated"
ok "...and its neighbour is still denied" \
  "$(home_reg_denied | grep -cx "$FAKE/.lastlight/unrelated" || true)" "1"
# ...and refused to the Edit tool, which the filesystem sandbox does not cover.
ok "...but the Edit tool is refused it" \
  "$(jq -r '.permissions.deny[]' <<< "$REG_POLICY" | grep -c "^Edit(/$REG" || true)" "2"
# ...and outside allowWrite, which is what stops Bash writing it.
ok "...and it is not writable by a spawned process" \
  "$(jq -r '.sandbox.filesystem.allowWrite[]' <<< "$REG_POLICY" | grep -c "$REG" || true)" "0"
work_registry_remove "$REG_WS"
unset LASTLIGHT_WORKSPACE_REGISTRY

echo "--- list must not invent workspaces ---"
# `find` descended INTO each clone, so any directory named `repo` inside a
# checked-out tree came back as a workspace of its own -- a project with
# tools/repo/ got a second, invented row, with state and SHA read from inside
# the real clone. Misleading about what is actually in flight.
#
# This runs `list`. The first version asserted on `find` directly, which meant
# mutating the script changed nothing and the case proved only that find works.
LIST_SRC=$TMP/listsrc
mkdir -p "$LIST_SRC"
git init -q -b main "$LIST_SRC"
git -C "$LIST_SRC" config user.email t@t
git -C "$LIST_SRC" config user.name t
echo x > "$LIST_SRC/f.txt"
git -C "$LIST_SRC" add f.txt
git -C "$LIST_SRC" commit -qm "feat: initial"

LIST_ROOT=$TMP/listwork
mkdir -p "$LIST_ROOT"

# `start` ends with `exec claude`, and its containment proof is a model call.
# Left alone, this case started a real session and spent tokens on every suite
# run -- in the plugin whose whole purpose is not spending them. A stub on PATH
# answers the exec, and VERIFY=off skips the probe. The workspace itself is
# still built by the real `start`, because that is the layout `list` reads and
# reproducing it here would mean copying the repo-key hash out of the script.
LIST_STUB=$TMP/liststub
mkdir -p "$LIST_STUB"
printf '#!/bin/sh\nexit 0\n' > "$LIST_STUB/claude"
chmod +x "$LIST_STUB/claude"

(
  cd "$LIST_SRC" || exit 1
  PATH=$LIST_STUB:$PATH LASTLIGHT_WORK_VERIFY=off LASTLIGHT_WORK_ROOT=$LIST_ROOT \
    "$WORK" start -b feat/listcase > /dev/null 2>&1
) || true

# A directory named `repo` INSIDE the checked-out tree, which is what the bug
# needed. Created after `start` so it lands in the clone rather than the source.
LIST_WS=$(find "$LIST_ROOT" -type d -name repo -prune -print 2> /dev/null | head -1)
if [[ -n $LIST_WS ]]; then
  mkdir -p "$LIST_WS/tools/repo" "$LIST_WS/vendor/repo"
fi

ok "one row per workspace, whatever the tree contains" \
  "$(cd "$LIST_SRC" && LASTLIGHT_WORK_ROOT=$LIST_ROOT "$WORK" list 2> /dev/null | grep -c .)" "1"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
