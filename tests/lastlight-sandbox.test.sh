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
# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
clear_inherited_config
pass=0
fail=0

# EXITS, like the runner's does. It used to return, so a function under test
# ran on past its own refusal and the assertion described the harness rather
# than the code -- and one case had to redefine this inside a subshell to get
# the real behaviour back, which then needed a linter exception to explain.
# A harness that models the thing under test incorrectly costs more than it
# saves. Every call here that can die already runs in a subshell, so exiting
# ends that and nothing else.
die() {
  printf 'die: %s\n' "$1" >&2
  exit 1
}
# shellcheck disable=SC1090  # path resolved at runtime from $SANDBOX
source "$SANDBOX"
# Sourcing brought that script's own `set -euo pipefail` with it, and the flags
# above were set BEFORE the source, so errexit has been on ever since. Any
# assertion whose command exits non-zero then kills the run where it stands --
# no summary, no FAIL line, exit 1, which reads as a crash rather than as the
# suite reporting something. Declare what this suite wants instead of
# inheriting it, the way the runner's suite already does.
set +e

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
# Scoped to THIS review, not the shared ${TMPDIR} root. allowWrite is recursive,
# so granting the root let a probe write over anything else staging through the
# same directory -- another concurrent session's scratch files included.
ok "...scoped to this review, beside the workspace" \
  "$(jq -r --arg t "$TMP/ws.tmp" '.sandbox.filesystem.allowWrite | index($t) != null' <<< "$POLICY")" "true"
ok "...and NOT the shared temp root" \
  "$(jq -r --arg t "$(cd "${TMPDIR:-/tmp}" && pwd -P)" \
    '.sandbox.filesystem.allowWrite | index($t) != null' <<< "$POLICY")" "false"
ok "...and nothing else" \
  "$(jq -r --arg w "$TMP/ws" --arg t "$TMP/ws.tmp" \
    '[.sandbox.filesystem.allowWrite[] | select(. != $w and . != $t)] | length' <<< "$POLICY")" "0"
# A SIBLING of the clone, not a directory inside it: inside, it would show up as
# untracked in the very tree the reviewer reads, and --working-tree mode copies
# untracked files in by design.
ok "scratch sits outside the clone" \
  "$(case "$(sandbox_scratch_dir "$TMP/ws")" in "$TMP/ws"/*) echo inside ;; *) echo outside ;; esac)" "outside"

echo "--- and the child is sent there, not at the shared root ---"
# Granting a directory the child never uses would leave `mktemp -d` failing
# exactly as it did before the grant existed, with probes reported as enabled.
SCRATCH_ENV=$(sandbox_scratch_env "$TMP/ws")
for v in TMPDIR TMP TEMP; do
  ok "$v is the scratch directory" \
    "$(printf '%s\n' "$SCRATCH_ENV" | grep -E "^${v}=" | cut -d= -f2-)" "$TMP/ws.tmp"
done

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
  ok "objects are NOT hardlinked to the source" "$(link_count "$obj")" "1"
else
  # A packed clone has no loose objects; assert the pack is unshared instead.
  pack=$(find "$WS/.git/objects/pack" -name '*.pack' | head -1)
  ok "pack is NOT hardlinked to the source" "$(link_count "$pack")" "1"
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
ok "uncommitted change applied" "$(count_matching modified "$WWS/f.txt")" "1"
ok "untracked file copied" "$([[ -f $WWS/new.txt ]] && echo yes || echo no)" "yes"
ok "ignored tree NOT copied" "$([[ -d $WWS/ignored ]] && echo copied || echo excluded)" "excluded"
ok "still an independent .git" "$([[ -d $WWS/.git ]] && echo yes || echo no)" "yes"
# The whole point of the mode: a plain clone would have none of the above.
PLAIN=$(cd "$REPO" && sandbox_make_workspace "$REPO" "$(git -C "$REPO" rev-parse HEAD)")
# Expecting 0 is the dangerous shape: a missing `rg` also produces 0, so this
# passed on a runner without it while testing nothing.
ok "a plain clone lacks it" "$(count_matching modified "$PLAIN/f.txt")" "0"

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

echo "--- a link out of the workspace is refused, not carried in ---"
# The COMMITTED path first, which is the one an incoming branch controls.
# `git checkout` materialises a symlink exactly as the branch spells it, so a
# branch could ship a link to anywhere on the host and the reviewer would read
# through it. Only the working-tree builder was covered at first, and removing
# the check from this one broke no assertion.
CLINK=$TMP/committed-link
mkdir -p "$CLINK/outside"
printf 'not for the reviewer\n' > "$CLINK/outside/target.txt"
git init -q -b main "$CLINK/repo"
git -C "$CLINK/repo" config user.email t@t
git -C "$CLINK/repo" config user.name t
printf 'x\n' > "$CLINK/repo/f.txt"
git -C "$CLINK/repo" add f.txt
git -C "$CLINK/repo" commit -qm "feat: initial"
CLINK_OK=$(git -C "$CLINK/repo" rev-parse HEAD)
ln -sfn "$CLINK/outside/target.txt" "$CLINK/repo/reaches-out"
git -C "$CLINK/repo" add reaches-out
git -C "$CLINK/repo" commit -qm "feat: link out"
CLINK_BAD=$(git -C "$CLINK/repo" rev-parse HEAD)

ok "a committed link out is refused" \
  "$( (sandbox_make_workspace "$CLINK/repo" "$CLINK_BAD" > /dev/null 2>&1) && echo made || echo refused)" \
  "refused"
# ...and the commit before it, in the same repository, still builds.
ok "...while the commit before it builds" \
  "$( (sandbox_make_workspace "$CLINK/repo" "$CLINK_OK" > /dev/null 2>&1) && echo made || echo refused)" \
  "made"

# `git checkout` materialises a committed symlink exactly as the branch spells
# it, and `cp -RP` preserves an untracked one. The reviewer is always granted
# Read, and everything it reads leaves through findings.json -- which is copied
# out by design, with no network involved. So a link committed by the branch
# was a read primitive for any path on the host, and the deny list stops at
# $HOME.
OUTLINK=$TMP/outward
mkdir -p "$OUTLINK"
printf 'not for the reviewer\n' > "$OUTLINK/target.txt"
ln -sfn "$OUTLINK/target.txt" "$REPO/reaches-out"
ok "a workspace linking out is refused" \
  "$( (sandbox_make_working_workspace "$REPO" > /dev/null 2>&1) && echo made || echo refused)" \
  "refused"
rm -f "$REPO/reaches-out"
# ...and with it gone the same repository builds, so the refusal is about the
# link rather than anything else in the tree.
ok "...and builds once it is gone" \
  "$( (sandbox_make_working_workspace "$REPO" > /dev/null 2>&1) && echo made || echo refused)" \
  "made"

echo "--- untracked files are copied faithfully, not approximately ---"
mkdir -p "$REPO/nested/deep"
echo nested > "$REPO/nested/deep/file.txt"
echo spaced > "$REPO/a file with spaces.txt"
# A directory whose name starts with a hyphen: dirname read it as options,
# printed nothing, and the copy then failed with a message naming the file
# rather than the reason.
mkdir -p "$REPO/-webpack-cache"
echo hyphen > "$REPO/-webpack-cache/thing.txt"
ln -sfn nested/deep/file.txt "$REPO/inside-link"
WWS2=$(sandbox_make_working_workspace "$REPO")
ok "untracked file in a new subdirectory" \
  "$([[ -f "$WWS2/nested/deep/file.txt" ]] && echo yes || echo no)" "yes"
ok "untracked filename containing spaces" \
  "$([[ -f "$WWS2/a file with spaces.txt" ]] && echo yes || echo no)" "yes"
ok "untracked file under a hyphen-led directory" \
  "$([[ -f "$WWS2/-webpack-cache/thing.txt" ]] && echo yes || echo no)" "yes"
# A symlink copied as its target drags a file from outside the repo INTO the
# workspace, which is the opposite of isolating the review.
ok "untracked symlink stays a symlink" \
  "$([[ -L "$WWS2/inside-link" ]] && echo yes || echo no)" "yes"

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

echo "--- denyRead must cover \$HOME, not just the curated stores ---"
# The curated list names the files that hold tokens. It does NOT stop a spawned
# process reading everything else: a sibling repo's .env, a shell history,
# another session's transcript under ~/.claude/projects. The Read TOOL is
# blocked from all of that by read_deny_rules, but a sandboxed reviewer is
# granted Bash -- so `cat ~/other-project/.env` went through the half of the
# policy that had no such rule, and findings.json is copied out of the
# workspace and posted publicly.
#
# The workspace lives under TMPDIR, not $HOME, so denying $HOME wholesale costs
# the reviewer nothing it needs.
ok "denyRead blocks \$HOME itself" \
  "$(jq -r --arg h "$HOME" '.sandbox.filesystem.denyRead | index($h) != null' <<< "$POLICY")" "true"
ok "review_denied_reads leads with \$HOME" \
  "$(review_denied_reads | head -1 | grep -cx "$HOME")" "1"
# The SHARED list must NOT carry it: the work sandbox derives from that one and
# its workspace lives under $HOME, where deny beats allow.
ok "the shared credential list does not" \
  "$(sandbox_denied_reads | grep -cx "$HOME")" "0"
ok "...and the Read rules come from the same place as denyRead" \
  "$(read_deny_rules | grep -cx "Read(/$HOME)")" "1"
# The specific stores stay listed. They cost nothing and say what the rule is
# for; XDG's location for git credentials is not under a blanket $HOME rule on
# a machine where XDG_CONFIG_HOME points elsewhere.
ok "...and still lists the credential stores" \
  "$(sandbox_denied_reads | grep -cx "$HOME/.ssh")" "1"
ok "...including the XDG git credentials path" \
  "$(sandbox_denied_reads | grep -c '/git/credentials$')" "1"

echo "--- the verdict judges the READ probe too ---"
# The escape canary tests whether the OS sandbox stops a spawned process
# writing out. It says nothing about the Read tool, which never sees
# sandbox.filesystem and is confined only by permissions.deny -- the
# mechanism that has broken silently twice here. A probe that does not
# exercise it reports containment either way.
verdict_read() {
  sandbox_probe_verdict 0 "$1" "$2"
  printf "%s" "$?"
}

TOK=lastlight-read-canary-999
ok "refused read is contained" "$(verdict_read 'ran rc=1 read=REFUSED' "$TOK")" "0"
# The token can only be in the report by having been read, whatever the
# model says about it.
ok "the token in the report is an escape" "$(verdict_read "ran rc=1 read=$TOK" "$TOK")" "1"
# Self-reporting alone proves nothing: a model that never tried looks
# exactly like one that was refused, so an absent read= is inconclusive.
ok "no read= at all is inconclusive" "$(verdict_read 'ran rc=1' "$TOK")" "2"
ok "...and inconclusive is not success" "$(verdict_read 'ran rc=1 rea=x' "$TOK")" "2"
# The write escape still outranks it: a sandbox that let the write through
# is a breach whatever the read did.
ok "an escaped write still reports 1" "$(
  sandbox_probe_verdict 1 'ran rc=1 read=REFUSED' "$TOK"
  printf %s $?
)" "1"

# A tool the probe is not granted is a policy the probe cannot test: it then
# answers "refused" whatever the rules say, and reports containment. That has
# happened twice here, once for Write and once for Read.
ok "the probe is granted Read" \
  "$(sandbox_probe_tools | grep -c Read)" "1"
ok "...and the full expected set" \
  "$(sandbox_probe_tools)" "Bash Read"

echo "--- the workspace must not carry the last review in with it ---"
# reviewer.log is never removed between runs, so on the documented
# run-it-again workflow the next session could read the previous one's whole
# transcript and reasoning -- an independent pass that is not independent.
#
# HOME is pointed at an empty directory for the git calls: --exclude-standard
# reads the global gitignore, and this machine's covers .lastlight/, so the
# leak does not happen here and does everywhere else.
LK_HOME=$(mktemp -d)
LK=$(mktemp -d)/repo
mkdir -p "$LK/.lastlight/pr-review"
git -C "$LK" init -q -b main 2> /dev/null || git init -q -b main "$LK"
git -C "$LK" config user.email p@example.com
git -C "$LK" config user.name p
printf 'one\n' > "$LK/f.txt"
git -C "$LK" add f.txt
git -C "$LK" commit -qm init
printf 'two\n' > "$LK/f.txt"
printf 'PRIOR-TRANSCRIPT\n' > "$LK/.lastlight/pr-review/reviewer.log"

LKWS=$(cd "$LK" && HOME=$LK_HOME sandbox_make_working_workspace "$LK")
ok "the previous reviewer.log is not carried in" \
  "$([[ -e $LKWS/.lastlight/pr-review/reviewer.log ]] && echo carried || echo absent)" "absent"
# ...and the change under review still is, or the exclusion took the subject
# with it.
ok "the uncommitted change is still there" \
  "$(count_matching two "$LKWS/f.txt")" "1"
rm -rf "$LK_HOME" "$(dirname "$LK")" "$(dirname "$LKWS")"
echo "--- the branch must not own the paths the runner writes into ---"
# Everything the runner puts in the workspace -- the settings file, the diff,
# the staged skill -- is written by THIS process, outside the sandbox, with the
# user's privileges. The workspace is a clone of the branch under review, so
# the branch chooses what is sitting at those names. Both halves were
# reproduced before the fix: `cp` wrote the diff through a committed symlink
# into a file outside the workspace, and a committed skill file stayed where
# the prompt points while the real one landed a level deeper.
RP=$TMP/runnerpaths
mkdir -p "$RP/.lastlight/pr-review" "$RP/.lastlight-assets/skills"
ln -s /etc/hosts "$RP/.lastlight/pr-review/diff.patch"
printf 'committed\n' > "$RP/.lastlight-sandbox.json"
sandbox_clear_runner_paths "$RP" 2> /dev/null

present() { [[ -e $1 || -L $1 ]] && printf 'present' || printf 'gone'; }
ok "a committed .lastlight is out of the write path" "$(present "$RP/.lastlight")" "gone"
ok "...and .lastlight-assets with it" "$(present "$RP/.lastlight-assets")" "gone"
ok "...and the settings path" "$(present "$RP/.lastlight-sandbox.json")" "gone"
# Moved, not destroyed: the workspace is disposable either way, and a branch
# that commits a symlink where the review tooling writes is worth the reviewer
# seeing.
ok "what the branch committed is kept" \
  "$(find "$RP" -maxdepth 1 -name '.lastlight.branch-committed.*' | grep -c .)" "1"

# A dangling symlink is the case that decides whether -L has to be asked for
# separately: -e follows the link and is false when the target is missing, so
# a test on -e alone walks straight past the redirect that matters most.
RPD=$TMP/runnerpaths-dangling
mkdir -p "$RPD"
ln -s "$TMP/no-such-target" "$RPD/.lastlight"
sandbox_clear_runner_paths "$RPD" 2> /dev/null
ok "a DANGLING symlink is moved too" "$(present "$RPD/.lastlight")" "gone"

# A workspace with none of them must come out unchanged -- no stray quarantine
# directories for the reviewer to trip over.
RPC=$TMP/runnerpaths-clean
mkdir -p "$RPC/src"
sandbox_clear_runner_paths "$RPC" 2> /dev/null
ok "a clean workspace is left alone" \
  "$(find "$RPC" -maxdepth 1 -name '*.branch-committed.*' | grep -c .)" "0"

echo "--- staging the skill must not stage it UNDER the branch's own ---"
# `cp -R src dst` copies INTO dst when dst exists as a directory, and exits 0.
# The committed SKILL.md then keeps the path the prompt hands the reviewer, and
# the prompt says to follow it EXACTLY -- so the branch under review writes its
# own review, mints an APPROVE, and the attestation binds it.
REAL=$TMP/realassets
mkdir -p "$REAL/skills/pr-review"
printf 'REAL\n' > "$REAL/skills/pr-review/SKILL.md"
SA=$TMP/stageassets
mkdir -p "$SA/.lastlight-assets/skills/pr-review"
printf 'ATTACKER\n' > "$SA/.lastlight-assets/skills/pr-review/SKILL.md"

# In a subshell, because the suite's die exits the way the runner's does -- so
# this ends the substitution and the suite carries on.
sa_out=$(sandbox_stage_assets "$REAL" "$SA" 2>&1) || true
ok "staging refuses a .lastlight-assets that is already there" \
  "$(grep -c 'refusing to stage' <<< "$sa_out")" "1"
# One SKILL.md, not two: had the copy run, the real skill would be sitting at
# .lastlight-assets/skills/skills/pr-review/SKILL.md beside the branch's.
ok "...and nothing was copied in on top" \
  "$(find "$SA" -name SKILL.md | grep -c .)" "1"

sandbox_clear_runner_paths "$SA" 2> /dev/null
sandbox_stage_assets "$REAL" "$SA"
ok "after clearing, the prompt path holds the real skill" \
  "$(cat "$SA/.lastlight-assets/skills/pr-review/SKILL.md")" "REAL"
ok "...and only the real one is staged" \
  "$(find "$SA/.lastlight-assets" -name SKILL.md | grep -c .)" "1"

echo "--- the reviewer gets an environment, not an inheritance ---"
# The policy denies every file-based credential store so a token cannot leave
# through the github egress the review deliberately opens. The environment went
# round all of it: `claude -p` inherited whatever was exported, so `printenv
# GITHUB_TOKEN` answered inside the sandbox. Not hypothetical -- GITHUB_TOKEN is
# exported on the machine this was found on.
tok_env=$(
  export GITHUB_TOKEN=fake GH_TOKEN=fake NPM_TOKEN=fake AWS_SECRET_ACCESS_KEY=fake
  sandbox_reviewer_env
)
ok "no exported token reaches the reviewer" \
  "$(grep -cE '^(GITHUB_TOKEN|GH_TOKEN|NPM_TOKEN|AWS_SECRET_ACCESS_KEY)=' <<< "$tok_env" || true)" "0"
# ...and it is still an environment a process can run in.
ok "PATH still reaches it" "$(grep -c '^PATH=' <<< "$tok_env" || true)" "1"
ok "HOME still reaches it" "$(grep -c '^HOME=' <<< "$tok_env" || true)" "1"

# A keep-list, for the reason read_deny_rules gives about reads: a denylist of
# token-shaped names protects the ones someone thought of.
ok "the keep-list names no credential variable" \
  "$(sandbox_env_keep | grep -ciE 'token|secret|password|credential' || true)" "0"

# The documented exception, asserted so it stays visible rather than implied:
# the session cannot authenticate without these, so scrubbing them would end
# the review rather than harden it.
anth_env=$(
  export ANTHROPIC_API_KEY=fake CLAUDE_CODE_SOMETHING=fake
  sandbox_reviewer_env
)
ok "ANTHROPIC_API_KEY is passed through, deliberately" \
  "$(grep -c '^ANTHROPIC_API_KEY=' <<< "$anth_env" || true)" "1"
ok "...and CLAUDE_* with it" \
  "$(grep -c '^CLAUDE_CODE_SOMETHING=' <<< "$anth_env" || true)" "1"

echo "--- the unsandboxed fallback still denies host reads ---"
# With no OS sandbox the reviewer used to run with no settings file at all, so
# it kept Read and no permissions.deny -- and a prompt injection in the diff
# could read anything the user can and copy it into findings.json, the artifact
# carried back out. "No Bash" is not containment.
DENYONLY=$(sandbox_read_deny_settings_json)

ok "it is a settings document" "$(jq -e 'type' <<< "$DENYONLY" 2> /dev/null)" '"object"'
# The SAME rules as the sandboxed path, not a second list that can drift.
ok "its denials are exactly read_deny_rules" \
  "$(jq -r '.permissions.deny[]' <<< "$DENYONLY" | sort | tr '\n' ' ')" \
  "$(read_deny_rules | sort | tr '\n' ' ')"
ok "$HOME itself is denied" \
  "$(jq -r '.permissions.deny[]' <<< "$DENYONLY" | grep -cx "Read(/$HOME)")" "1"
# No sandbox block: there are no spawned processes to confine without Bash, and
# asking for one here is what the caller has already found unavailable.
ok "it claims no OS sandbox" "$(jq -r 'has("sandbox")' <<< "$DENYONLY")" "false"
ok "hooks are still disabled" "$(jq -r '.disableAllHooks' <<< "$DENYONLY")" "true"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
