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
ok "--model without a value is rejected" "$(refused --model)" "lastlight-review-run: --model needs a value"
# A base ref with --working-tree is two different answers to "review what?",
# and the loser used to be the one the caller typed: `main` overwrote the base
# with HEAD, reviewed only the uncommitted changes, and exited 0. A review that
# covers less than the caller asked for and says nothing is the failure this
# whole script exists to prevent.
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
# guaranteed ABSENT. `Edit` cannot create a file -- only `Write` can -- so with
# Edit alone the reviewer stalls asking for permission and the run dies having
# spent the model call. It only ever succeeded when the reviewer improvised
# with `Bash`, which is not granted unsandboxed at all.
ok "unsandboxed grants Write on the findings file" \
  "$(tools_for '' | grep -cx 'Write(.lastlight/pr-review/findings.json)')" "1"
ok "sandboxed grants it too" \
  "$(tools_for /tmp/ws | grep -cx 'Write(.lastlight/pr-review/findings.json)')" "1"
ok "an override still gets it appended" \
  "$(tools_for '' 'Read,Grep' | grep -cx 'Write(.lastlight/pr-review/findings.json)')" "1"

# Scoped, not bare. An unscoped Write would let the reviewer edit the code it
# is reviewing -- including the guard scripts -- which is the whole reason the
# rule is written as a path.
ok "the Write is scoped to that one path" \
  "$(tools_for '' | grep -cx 'Write')" "0"
ok "...and so is the Edit" \
  "$(tools_for '' | grep -cx 'Edit')" "0"
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
WRULE=$(printf "%s\n" "${REVIEW_TOOLS[@]}" | grep -m1 "^Write(")
WPATH=${WRULE#Write(}
WPATH=${WPATH%)}

ok "the rule is relative" "$([[ $WPATH == /* ]] && echo absolute || echo relative)" "relative"
ok "the prompt names that exact path" \
  "$([[ $PROMPT == *"to $WPATH"* ]] && echo yes || echo no)" "yes"
# ...and not the absolute form, which the rule would not match.
ok "the prompt does not ask for an absolute write" \
  "$([[ $PROMPT == *"/some/root/$WPATH"* ]] && echo yes || echo no)" "no"
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
  "$(
    # shellcheck disable=SC2329  # invoked indirectly: this shadows the
    # binary that findings_contained calls, which is the whole test.
    find() { return 127; }
    contained "$WS"
  )" "no"
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

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
