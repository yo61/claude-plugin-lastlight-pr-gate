#!/usr/bin/env bash
# shellcheck disable=SC2154  # WORKING_TREE, MODEL, REST, DEFAULT_MODEL and
# DEFAULT_TOOLS are assigned by the script this suite sources; asserting on
# them is the entire point, so shellcheck cannot see where they come from.
#
# Test suite for lastlight-review-run.sh — the orchestrator.
#
# This is the script that decides whether the reviewer gets unrestricted Bash,
# parses the flags, and writes the attestation the whole push gate rests on.
# It was the only one of the four without a suite, and two of its
# argument-parsing bugs had already been found by hand — neither would have
# survived a test, and neither had one.
#
# The decisions are exercised as functions. Nothing here starts a review or
# spends a model call: a check that costs money per assertion stops being run.
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

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
clear_inherited_config
RUN="${RUN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lastlight-review-run.sh}"
RUN=$(cd "$(dirname "$RUN")" && printf '%s/%s' "$PWD" "$(basename "$RUN")")
[[ -f $RUN ]] || {
  printf 'no script at %s\n' "$RUN" >&2
  exit 1
}

# Sourcing must not run a review. Without the guard this file loads, that is
# exactly what happens — found the hard way.
# shellcheck disable=SC1090  # path resolved at runtime from $RUN
source "$RUN"
# Sourcing brought the script's own `set -euo pipefail` with it, which turns on
# errexit here and would kill the run at the first failing assertion, before
# the summary. Declare what this suite wants instead of inheriting it.
set +e

# ── option parsing ───────────────────────────────────────────────────────
echo "--- parse_options: order must not matter ---"
parsed() {
  # Each call in a subshell: parse_options sets globals, and a later case must
  # not read a value an earlier one left behind.
  (
    unset LASTLIGHT_REVIEW_MODEL
    parse_options "$@" > /dev/null 2>&1
    printf 'wt=%s model=%s rest=%s' "$WORKING_TREE" "$MODEL" "${REST[*]+${REST[*]}}"
  )
}

ok "no flags" "$(parsed)" "wt=0 model=sonnet rest="
ok "a base ref alone" "$(parsed origin/main)" "wt=0 model=sonnet rest=origin/main"
ok "--working-tree" "$(parsed --working-tree)" "wt=1 model=sonnet rest="
ok "--model" "$(parsed --model opus)" "wt=0 model=opus rest="
# The bug this loop replaced: checking each flag only in position one left the
# second sitting where the base ref is read, so the mode silently did not
# engage and the run died complaining about a merge base.
ok "--model then --working-tree" "$(parsed --model opus --working-tree)" "wt=1 model=opus rest="
ok "--working-tree then --model" "$(parsed --working-tree --model opus)" "wt=1 model=opus rest="
# This case used to assert that a base ref survives --working-tree, which is
# what the parser did -- and then `main` overwrote the base with HEAD and
# reviewed something narrower than was asked for. The suite was documenting the
# bug as the contract. The combination is refused now; see the refusal below.
ok "a flag then a base ref, for a flag that takes one" \
  "$(parsed --model opus origin/main)" "wt=0 model=opus rest=origin/main"

echo "--- parse_options: the environment is a default, not an override ---"
ok "LASTLIGHT_REVIEW_MODEL is used when no flag is given" \
  "$(LASTLIGHT_REVIEW_MODEL=haiku bash -c 'source "$1"; parse_options; printf %s "$MODEL"' _ "$RUN")" \
  "haiku"
ok "...and the flag still wins over it" \
  "$(LASTLIGHT_REVIEW_MODEL=haiku bash -c 'source "$1"; parse_options --model opus; printf %s "$MODEL"' _ "$RUN")" \
  "opus"

echo "--- parse_options: bad input is named, not read as a ref ---"
refused() {
  local out
  out=$(bash -c 'source "$1"; shift; parse_options "$@"' _ "$RUN" "$@" 2>&1)
  printf '%s' "$out" | head -1
}
# A bare `-h` once fell past a loop matching only `--*` and landed in the
# base-ref slot, so the flag died on a merge-base error instead of helping.
ok "-h reaches the usage text" \
  "$(bash -c 'source "$1"; parse_options -h' _ "$RUN" 2>&1 | grep -c 'INDEPENDENT pass')" "1"
ok "--help does too" \
  "$(bash -c 'source "$1"; parse_options --help' _ "$RUN" 2>&1 | grep -c 'INDEPENDENT pass')" "1"
ok "an unknown flag is rejected" "$(refused --bogus)" "lastlight-review-run: unknown option: --bogus"
ok "...and so is a short one" "$(refused -x)" "lastlight-review-run: unknown option: -x"
# macOS ships no `timeout`, and the runner uses it to bound both the reviewer
# session and the containment probe. Undeclared, its absence was swallowed by
# the probe's `|| true` and the run died blaming the model for being
# unavailable. gtimeout counts, since that is what Homebrew coreutils installs.
# The thing CHECKED FOR has to be the thing RUN. The first version accepted
# `gtimeout` while every call site executed the literal `timeout` through
# `env`, which resolves from PATH -- so a machine carrying only the g-prefixed
# build passed the check and failed every call with 127, swallowed by the
# probe's `|| true`. A declaration that made the misdiagnosis harder to find.
ok "the runner asks the resolver, not a name nobody runs" \
  "$(grep -c 'sandbox_timeout_cmd' "$RUN")" "2"
ok "no call site execs a literal timeout" \
  "$(grep -cE '(^|[^_])timeout [0-9$]' "$RUN")" "0"
# ...and whatever it names is a command that exists. NOT "it returns timeout":
# on a machine carrying only gtimeout the resolver correctly says so and the
# runner works fine, and that assertion took the suite, the prek hook and
# readme-counts down with it. A `command -v` guard would have made the printed
# total vary by machine, which readme-counts compares -- so the assertion is
# machine-independent instead of conditional.
ok "the resolver names a command that exists" \
  "$(command -v "$(sandbox_timeout_cmd)" > /dev/null 2>&1 && echo yes || echo no)" "yes"

ok "--model without a value is rejected" "$(refused --model)" "lastlight-review-run: --model needs a value"
# A base ref with --working-tree is two different answers to "review what?",
# and the loser used to be the one the caller typed: `main` overwrote the base
# with HEAD, reviewed only the uncommitted changes, and exited 0. A review that
# covers less than the caller asked for and says nothing is the failure this
# whole script exists to prevent.
# ...in EITHER order. The loop stopped at the first non-flag word, so with the
# ref written first the flag stayed unparsed in REST: the refusal below never
# fired, and the run reviewed the committed diff and exited 0. The silent
# reinterpretation that refusal exists to prevent, avoided only by writing the
# flags first.
ok "...and with the ref written first" \
  "$(refused origin/main --working-tree | grep -c "given as one")" "1"
ok "a flag after the ref is still parsed" \
  "$(parsed origin/main --model opus)" "wt=0 model=opus rest=origin/main"

ok "--working-tree with a base ref is refused" \
  "$(refused --working-tree origin/main)" \
  "lastlight-review-run: --working-tree reviews what is not yet committed, so there is nothing to compare against a base ref -- but 'origin/main' was given as one. Pass one or the other: the ref alone reviews the branch, --working-tree alone reviews the uncommitted changes."
ok "...whichever order they come in" \
  "$(refused --working-tree origin/main | grep -c "given as one")" "1"
# Each alone stays valid: the refusal is about the combination.
ok "--working-tree alone is fine" "$(parsed --working-tree)" "wt=1 model=sonnet rest="
ok "a base ref alone is still fine" "$(parsed origin/main)" "wt=0 model=sonnet rest=origin/main"

# ── the prompt ───────────────────────────────────────────────────────────
echo "--- prompt: points at the assets it is given ---"
P=$(prompt /repo origin/main abc1234 /staged/assets)
# Staged rather than referenced where they live, because the reviewer's reads
# are scoped to the workspace: pointing at the real location would deny it its
# own instructions.
ok "the skill path comes from the argument" \
  "$(grep -c '/staged/assets/skills/pr-review/SKILL.md' <<< "$P")" "1"
ok "the companion skill too" \
  "$(grep -c '/staged/assets/skills/code-review/SKILL.md' <<< "$P")" "1"
ok "no path leaks from the caller's environment" \
  "$(grep -c "$HOME/.claude/lastlight-review" <<< "$P")" "0"
ok "the head SHA is stated" "$(grep -c 'abc1234' <<< "$P")" "1"
ok "the base is stated" "$(grep -c 'origin/main' <<< "$P")" "1"
# The reviewer must not treat the diff as its own work.
ok "it says the code is not the reviewer's" \
  "$(grep -c 'did NOT write this code' <<< "$P")" "1"
ok "it forbids posting to GitHub" "$(grep -c 'Do not post anything to GitHub' <<< "$P")" "1"

# ── defaults ─────────────────────────────────────────────────────────────
echo "--- defaults ---"
# Matching Last Light's own models.default, so the local pass runs at the tier
# the server's would rather than inheriting the invoking session's.
ok "the model default matches Last Light's" "$DEFAULT_MODEL" "sonnet"
ok "the unsandboxed tool list is read-only" \
  "$(printf '%s\n' "${DEFAULT_TOOLS[@]}" | grep -c '^Write')" "0"
ok "...and grants no arbitrary Bash" \
  "$(printf '%s\n' "${DEFAULT_TOOLS[@]}" | grep -cx 'Bash')" "0"

# ── the tool allowlist ───────────────────────────────────────────────────
echo "--- review_tools: the reviewer must be able to CREATE its findings ---"
tools_for() {
  (
    unset LASTLIGHT_REVIEW_TOOLS
    [[ -n ${2:-} ]] && export LASTLIGHT_REVIEW_TOOLS="$2"
    review_tools "$1"
    printf '%s\n' "${REVIEW_TOOLS[@]}"
  )
}

# The run deletes a stale findings.json before starting, so the file is
# guaranteed ABSENT -- the rule has to authorise CREATING it, not just editing
# one that is already there.
#
# An Edit(path) rule does exactly that. This once carried a Write(path) rule
# beside it, on the reasoning that "Edit cannot create a file, only Write can";
# that confuses what the Edit TOOL does with what an Edit RULE matches. Probed
# directly against the CLI -- one `claude -p` asked to create a file, granted
# `Edit(out.txt)` and nothing else -- the file was created and the run exited
# 0. The rule form is what the CLI matches, and it covers every file-editing
# tool, Write included.
ok "unsandboxed grants Edit on the findings file" \
  "$(tools_for '' | grep -cx 'Edit(.lastlight/pr-review/findings.json)')" "1"
ok "sandboxed grants it too" \
  "$(tools_for /tmp/ws | grep -cx 'Edit(.lastlight/pr-review/findings.json)')" "1"
ok "an override still gets it appended" \
  "$(tools_for '' 'Read,Grep' | grep -cx 'Edit(.lastlight/pr-review/findings.json)')" "1"

# Scoped, not bare. An unscoped grant would let the reviewer edit the code it
# is reviewing -- including the guard scripts -- which is the whole reason the
# rule is written as a path.
ok "the grant is scoped to that one path" \
  "$(tools_for '' | grep -cx 'Edit')" "0"
# ...and no Write rule at all: the CLI rejects one, and a rejected rule is the
# under-equipped-reviewer case this script calls fatal.
ok "and no Write rule is emitted" \
  "$(tools_for '' | grep -c '^Write' || true)" "0"
ok "sandboxed grants no bare Write either" \
  "$(tools_for /tmp/ws | grep -cx 'Write')" "0"

# The behaviour the extraction must not change.
ok "unsandboxed stays read-only apart from those two" \
  "$(tools_for '' | grep -c '^Bash$')" "0"
ok "sandboxed widens to Bash" \
  "$(tools_for /tmp/ws | grep -cx 'Bash')" "1"
ok "an explicit override wins over the sandbox widening" \
  "$(tools_for /tmp/ws 'Read,Grep' | grep -cx 'Bash')" "0"
# Asserted with a tool the default list does NOT contain, and by the absence of
# one it does: checking for something present in both cannot tell a respected
# override from an ignored one.
ok "an override is honoured verbatim" \
  "$(tools_for '' 'Read,WebFetch' | grep -cx 'WebFetch')" "1"
ok "...and REPLACES the default rather than extending it" \
  "$(tools_for '' 'Read,WebFetch' | grep -cx 'Glob')" "0"

echo "--- base_needed: --working-tree must not require a remote ---"
needed() { base_needed "$1" "$2" && echo yes || echo no; }

# The bug: the base was resolved before the flag was read, so a repository
# with no reachable origin/main died on the merge base before --working-tree
# was honoured -- the usage the README documents with no base ref given.
#
# main() reaches the network and starts a review, so no case calls it; the
# decision is a function for exactly that reason.
ok "working-tree, no base given" "$(needed '' 1)" "no"
ok "committed, no base given" "$(needed '' 0)" "yes"
ok "a base given is never re-resolved" "$(needed origin/main 0)" "no"
ok "...not in working-tree mode either" "$(needed origin/main 1)" "no"

echo "--- working_tree_diff: the patch must not contain itself ---"
# The caller redirects this into .lastlight/pr-review/diff.patch, and a
# redirect creates its target before the command runs -- so the untracked
# listing finds the output file and the diff embeds a copy of itself.
#
# HOME is pointed at an empty directory FOR THE GIT CALLS, deliberately.
# `--exclude-standard` reads the global gitignore, and this machine's covers
# `.lastlight/`, so the bug is invisible here and present for everyone else.
# A test that inherits that config would pass without exercising anything.
WTD_HOME=$(mktemp -d)
WTD_REPO=$(mktemp -d)/repo
mkdir -p "$WTD_REPO/.lastlight/pr-review"
git -C "$WTD_REPO" init -q -b main
git -C "$WTD_REPO" config user.email p@example.com
git -C "$WTD_REPO" config user.name p
printf 'one\n' > "$WTD_REPO/f.txt"
git -C "$WTD_REPO" add f.txt
git -C "$WTD_REPO" commit -qm init
printf 'two\n' > "$WTD_REPO/f.txt"   # tracked, modified
printf 'new\n' > "$WTD_REPO/new.txt" # untracked

wtd_patch() {
  (
    cd "$WTD_REPO" && HOME=$WTD_HOME working_tree_diff > .lastlight/pr-review/diff.patch
    cat .lastlight/pr-review/diff.patch
  )
}
WTD=$(wtd_patch)

ok "the patch does not include itself" \
  "$(printf '%s' "$WTD" | grep -c 'diff\.patch' || true)" "0"
# ...and it still carries what it is for. A patch that excluded everything
# would pass the assertion above and be useless.
ok "a tracked change is in it" \
  "$([[ $WTD == *f.txt* ]] && echo yes || echo no)" "yes"
ok "an untracked file is in it" \
  "$([[ $WTD == *new.txt* ]] && echo yes || echo no)" "yes"
rm -rf "$WTD_HOME" "$(dirname "$WTD_REPO")"

echo "--- tool_rule_rejected: the check must not need an undeclared tool ---"
TRR=$(mktemp -d)
printf 'all fine\n' > "$TRR/clean.log"
printf 'Ignoring --allowedTools rule: bad\n' > "$TRR/rejected.log"
trr() { tool_rule_rejected "$1" && echo yes || echo no; }

ok "a rejected rule is detected" "$(trr "$TRR/rejected.log")" "yes"
ok "a clean log is not" "$(trr "$TRR/clean.log")" "no"
ok "a missing log is not, and does not crash" "$(trr "$TRR/absent.log")" "no"

# The wording the CLI uses TODAY, copied from a real run. The pattern knew only
# the older phrasing, so the guard went quiet when the message changed and a
# rejected rule rode through unreported -- which is how a Write(path) rule this
# script emitted itself reached a review unnoticed.
printf '%s\n' \
  'Permission allow rule (--allowed-tools): Write(.lastlight/pr-review/findings.json) is not matched by file permission checks - only Edit(path) rules are. Use Edit(.lastlight/pr-review/findings.json) instead (Edit rules cover all file-editing tools).' \
  > "$TRR/current.log"
ok "the current CLI wording is detected too" "$(trr "$TRR/current.log")" "yes"
# ...and prose that merely mentions permissions is not a rejection.
printf 'checking permission rules for the session\n' > "$TRR/chatty.log"
ok "an ordinary mention of rules is not" "$(trr "$TRR/chatty.log")" "no"

echo "--- the runner refuses a skipped review ---"
# The reviewer writes this file inside the sandbox, having read a diff this
# script calls untrusted. `skip` is the schema's own escape hatch for GitHub
# conditions no local run can be in, so a diff that persuades the reviewer to
# set it would otherwise produce an attestation for a review that never ran.
SKIPDIR=$(mktemp -d)
printf '{"skip": true}' > "$SKIPDIR/skip.json"
printf '{"skip": false, "event": "APPROVE"}' > "$SKIPDIR/ok.json"
printf '{"event": "APPROVE"}' > "$SKIPDIR/absent.json"

ok "a skipped review is recognised" "$(findings_skipped "$SKIPDIR/skip.json")" "yes"
ok "an ordinary one is not" "$(findings_skipped "$SKIPDIR/ok.json")" "no"
ok "...nor is one that omits the field" "$(findings_skipped "$SKIPDIR/absent.json")" "no"
# ...and the run acts on it. Asserting on the helper alone leaves the wiring
# untested, which is how the timeout message below kept a second opinion.
ok "the run refuses when it says yes" \
  "$(grep -c 'findings_skipped "' "$RUN" || true)" "1"
rm -rf "$SKIPDIR"

echo "--- a timeout must not assert what the log contains ---"
# It said the log was empty "by construction", reasoning that SIGTERM flushes
# nothing. The CLI writes startup diagnostics long before the kill, so a run
# that timed out with a rejected rule in the log was sent to raise the timeout
# -- the wrong next step -- by a message that had just called the file empty.
: > "$TRR/empty.log"
printf 'something the CLI said before it died\n' > "$TRR/spoke.log"

ok "an empty log is described as empty" \
  "$(timeout_message "$TRR/empty.log" 900 | grep -c 'is empty' || true)" "1"
ok "a log with content is not" \
  "$(timeout_message "$TRR/spoke.log" 900 | grep -c 'is empty' || true)" "0"
ok "...and the reader is sent to it" \
  "$(timeout_message "$TRR/spoke.log" 900 | grep -c "$TRR/spoke.log" || true)" "1"
# A log that was never created reads as empty rather than crashing.
ok "a missing log is described as empty" \
  "$(timeout_message "$TRR/absent.log" 900 | grep -c 'is empty' || true)" "1"
ok "the timeout is named so it can be raised" \
  "$(timeout_message "$TRR/empty.log" 900 | grep -c '900s' || true)" "1"

# ...and the call site actually defers to it. Asserting on the helper alone
# left the wiring untested: restoring the old hardcoded message at the call
# site broke no assertion, because the helper was still present and still
# right. The runner must not carry a second opinion about the log.
ok "the timeout branch defers to it" \
  "$(grep -c 'timeout_message "' "$RUN" || true)" "1"
ok "nothing else claims to know the log is empty" \
  "$(grep -c 'reviewer.log is empty' "$RUN" || true)" "0"

# The check was written with `rg`, which this script does not require. On a
# machine without it the command exits 127, the `if` body is skipped, and an
# under-equipped reviewer still writes an attestation. This asserts the
# scripts invoke no command they do not declare.
undeclared_tools() {
  # Command position only: `Bash(rg:*)` inside a tool rule is a permission
  # granted to the reviewer, not a dependency of this script. Comment lines are
  # dropped for the same reason -- prose about ripgrep is not a call to it.
  local dir
  dir=$(dirname "$RUN")
  grep -nE '(^|[;|&(])[[:space:]]*(rg|fd|trash)[[:space:]]' "$dir"/*.sh 2> /dev/null \
    | grep -v ':[0-9]*:[[:space:]]*#' || true
}
ok "no script depends on an undeclared tool" "$(undeclared_tools | wc -l | tr -d ' ')" "0"
rm -rf "$TRR"

echo "--- the prompt and the write rule must name the same path ---"
# They are set in two places and only work together. The prompt asked for an
# absolute path while the rule grants a relative one, which the rule does not
# match. Sandboxed that survived, because Bash is granted there and the
# reviewer could write the file another way; in the unsandboxed fallback the
# tool list IS the boundary, so the run spent the review and then failed for
# want of a findings file -- on exactly the platforms with no sandbox.
PROMPT=$(prompt /some/root origin/main deadbeef /some/assets)
review_tools ''
# Edit, not Write. A path rule is matched only as Edit(path) -- and an Edit
# rule already covers every file-editing tool -- so a Write(path) rule beside
# it is not redundant belt and braces, it is rejected, which this script treats
# as a fatal under-equipped reviewer. It emitted one and tripped its own guard.
ok "no Write rule is emitted" \
  "$(printf "%s\n" "${REVIEW_TOOLS[@]}" | grep -c "^Write(" || true)" "0"
WRULE=$(printf "%s\n" "${REVIEW_TOOLS[@]}" | grep -m1 "^Edit(")
WPATH=${WRULE#Edit(}
WPATH=${WPATH%)}
ok "the findings file is granted to Edit" \
  "$([[ -n $WRULE ]] && echo yes || echo no)" "yes"

ok "the rule is relative" "$([[ $WPATH == /* ]] && echo absolute || echo relative)" "relative"
ok "the prompt names that exact path" \
  "$([[ $PROMPT == *"to $WPATH"* ]] && echo yes || echo no)" "yes"
# ...and not the absolute form, which the rule would not match.
ok "the prompt does not ask for an absolute write" \
  "$([[ $PROMPT == *"/some/root/$WPATH"* ]] && echo yes || echo no)" "no"
echo "--- the unsandboxed branch passes a settings file ---"
# It used to pass none, which is what left Read unrestricted there. Asserted on
# the source because the branch only runs on a machine with no OS sandbox, and
# the thing that went wrong was its absence rather than its content.
ok "the fallback builds a deny-only policy" \
  "$(grep -c 'sandbox_read_deny_settings_json' "$RUN")" "1"
ok "...and hands it to the reviewer" \
  "$(grep -c 'extra_args=(--settings' "$RUN")" "2"

echo "--- the runner must not write through a committed symlink ---"
# These writes happen in the REAL repository, before any workspace exists --
# this process, outside any sandbox, with the user's privileges, on a checkout
# of the branch under review. A branch that commits a symlink at
# .lastlight/pr-review/diff.patch redirects the write anywhere. Reproduced
# before the fix: a file outside the repository was overwritten with the
# runner's own output.
#
# The workspace copy of this is handled by moving the names aside; that is
# wrong here, because this is the user's working tree and the directory holds
# the artefacts of previous runs.
RS=$(mktemp -d)
mkdir -p "$RS/repo/.lastlight/pr-review"
printf 'original\n' > "$RS/victim"
ln -s "$RS/victim" "$RS/repo/.lastlight/pr-review/diff.patch"

ok "a symlink at an output path is refused" \
  "$( (refuse_symlinked_outputs "$RS/repo") 2>&1 | grep -c 'is a symlink' || true)" "1"
ok "...and the target is untouched" "$(cat "$RS/victim")" "original"
# An ordinary directory with real files has to pass, or the guard blocks every
# run rather than the one case it is for.
rm -f "$RS/repo/.lastlight/pr-review/diff.patch"
printf 'x\n' > "$RS/repo/.lastlight/pr-review/diff.patch"
ok "an ordinary output directory passes" \
  "$( (refuse_symlinked_outputs "$RS/repo") 2>&1 | grep -c 'is a symlink' || true)" "0"
# ...and ANY symlink in there, not a list of the names written today. The first
# version enumerated them and missed reviewer.log, which the runner redirects
# into at the point it starts the reviewer.
ln -s "$RS/victim" "$RS/repo/.lastlight/pr-review/reviewer.log"
ok "a symlink at reviewer.log is refused too" \
  "$( (refuse_symlinked_outputs "$RS/repo") 2>&1 | grep -c 'is a symlink' || true)" "1"
rm -f "$RS/repo/.lastlight/pr-review/reviewer.log"
# A name nobody has written yet is covered by the same scan.
ln -s "$RS/victim" "$RS/repo/.lastlight/pr-review/something-new.json"
ok "...and one nobody writes yet" \
  "$( (refuse_symlinked_outputs "$RS/repo") 2>&1 | grep -c 'is a symlink' || true)" "1"
rm -f "$RS/repo/.lastlight/pr-review/something-new.json"
# The directory itself, and its parent.
ln -s /tmp "$RS/repo/.lastlight/linked"
ok "an unrelated symlink beside it is ignored" \
  "$( (refuse_symlinked_outputs "$RS/repo") 2>&1 | grep -c 'is a symlink' || true)" "0"

echo "--- findings_contained: the copy-back must not follow a link out ---"
# Ground truth, not a mock: real directories, real links, and the same helper
# `main` calls. The escape this closes was reproduced first -- a symlink at
# findings.json passed `[[ -f ]]`, `cp` dereferenced it, and the file it named
# arrived in the real repository as the review's findings.
#
# The copy runs OUTSIDE the sandbox, so what these assert is not "the reviewer
# behaved" but "this process refuses to be used as the reviewer's hands".
FC=$(mktemp -d)
FC_OUTSIDE=$FC/outside-secret.json
printf '{"token":"not-in-the-workspace"}\n' > "$FC_OUTSIDE"

# $1 workspace name; leaves $FC/$1/.lastlight/pr-review created and empty.
fc_ws() {
  local ws=$FC/$1
  mkdir -p "$ws/$OUT_DIR"
  printf '%s' "$ws"
}

contained() {
  if findings_contained "$1"; then printf 'yes'; else printf 'no'; fi
}

WS=$(fc_ws plain)
printf '{"findings":[]}\n' > "$WS/$OUT_DIR/findings.json"
ok "a file the reviewer wrote is copied" "$(contained "$WS")" "yes"

WS=$(fc_ws symlink)
ln -s "$FC_OUTSIDE" "$WS/$OUT_DIR/findings.json"
ok "a symlink pointing outside is refused" "$(contained "$WS")" "no"
# The escape as it actually presents itself: the guard that was there agreed
# the path was a file, which is why the copy went ahead.
ok "...and it is a link the old check called a file" \
  "$([[ -f $WS/$OUT_DIR/findings.json ]] && printf 'yes')" "yes"

WS=$(fc_ws danglinglink)
ln -s "$FC/nothing-here.json" "$WS/$OUT_DIR/findings.json"
ok "a dangling symlink is refused" "$(contained "$WS")" "no"

# A link one level up: the file at the end is real and is not a link, so only
# resolving the directory catches it.
WS=$FC/dirlink
mkdir -p "$WS" "$FC/elsewhere/pr-review"
ln -s "$FC/elsewhere" "$WS/.lastlight"
printf '{"findings":[]}\n' > "$FC/elsewhere/pr-review/findings.json"
ok "a symlinked .lastlight is refused" "$(contained "$WS")" "no"
ok "...though the path itself is a plain file" \
  "$([[ ! -L $WS/$OUT_DIR/findings.json && -f $WS/$OUT_DIR/findings.json ]] && printf 'yes')" "yes"

WS=$(fc_ws hardlink)
ln "$FC_OUTSIDE" "$WS/$OUT_DIR/findings.json"
ok "a hardlink to a file outside is refused" "$(contained "$WS")" "no"

WS=$(fc_ws absent)
ok "nothing written at all is refused" "$(contained "$WS")" "no"

# The check has to be positive: a find that cannot run must refuse, not wave
# the file through. Shadowing it in a subshell is the cheapest way to ask.
WS=$(fc_ws toolgone)
printf '{"findings":[]}\n' > "$WS/$OUT_DIR/findings.json"
ok "...and so is a file whose link count could not be read" \
  "$(PATH=/nonexistent contained "$WS")" "no"
ok "the same file passes when find works" "$(contained "$WS")" "yes"

echo "--- reviewer_git_env: git must be quiet AND still work ---"
# The sandbox denies $HOME, and git looks there for four things. Asserted
# against git itself rather than against the list: GIT_CONFIG_COUNT has to
# agree with the number of KEY_n pairs, and a mismatch drops the last override
# silently -- git reads exactly COUNT of them and never complains about the
# rest.
RGE=()
while IFS= read -r kv; do RGE+=("$kv"); done < <(reviewer_git_env)

git_with_env() { env "${RGE[@]}" git "$@" 2>&1; }

ok "the global config is taken out of $HOME" \
  "$(printf '%s\n' "${RGE[@]}" | grep -c '^GIT_CONFIG_GLOBAL=/dev/null$')" "1"
ok "and the system config with it" \
  "$(printf '%s\n' "${RGE[@]}" | grep -c '^GIT_CONFIG_NOSYSTEM=1$')" "1"
# These two are the ones that matter and the ones an obvious fix leaves out:
# GIT_CONFIG_GLOBAL does not govern where excludes and attributes are looked
# for, so without them git still reaches into $HOME and still warns.
ok "core.excludesFile is really applied" \
  "$(git_with_env config --get core.excludesFile)" "/dev/null"
ok "core.attributesFile is really applied" \
  "$(git_with_env config --get core.attributesFile)" "/dev/null"
# The count and the keys must agree, or git silently ignores the surplus.
ok "GIT_CONFIG_COUNT matches the keys given" \
  "$(printf '%s\n' "${RGE[@]}" | grep -c '^GIT_CONFIG_KEY_[0-9]*=')" \
  "$(printf '%s\n' "${RGE[@]}" | sed -n 's/^GIT_CONFIG_COUNT=//p')"
# Whatever else changes, the reviewer must still be able to use git.
ok "git still works under it" "$(git_with_env rev-parse --is-inside-work-tree)" "true"

# This process computes the attestation's diff hash with `git hash-object`,
# which applies the clean filter that core.attributesFile selects. If these
# were exported rather than set on the reviewer's command, the hash the
# recorder checks would be computed under a different attributes file.
ok "they are not exported into this process" \
  "${GIT_CONFIG_COUNT:-unset}${GIT_CONFIG_GLOBAL:-}" "unset"
# ...and that assertion means something only because the suite cleared these
# first. Claude Code's own sandbox exports GIT_CONFIG_COUNT=2, so inherited it
# read the invoking shell rather than the code under test -- and a bare COUNT
# with no matching KEY makes git fail outright, which took four other suites
# down with it. The clearing is asserted here so it cannot quietly stop
# happening.
ok "the suite cleared the git config it must not inherit" \
  "$(env | grep -c '^GIT_CONFIG_' || true)" "0"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
