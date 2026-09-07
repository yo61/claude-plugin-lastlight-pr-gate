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
ok "flags then a base ref" "$(parsed --working-tree origin/main)" "wt=1 model=sonnet rest=origin/main"

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

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
