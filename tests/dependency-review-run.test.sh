#!/usr/bin/env bash
# Test suite for dependency-review-run.sh; no case starts a review or spends a model call.
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
DEP="${DEP:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/dependency-review-run.sh}"
[[ -f $DEP ]] || {
  printf 'no script at %s\n' "$DEP" >&2
  exit 1
}

# shellcheck disable=SC1090  # path resolved at runtime from $DEP
source "$DEP"
set +e

SHA=0123456789abcdef0123456789abcdef01234567
OTHER=fedcba9876543210fedcba9876543210fedcba98
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ── argument validation ──────────────────────────────────────────────────
echo "--- validate_args ---"
valid() { (validate_args "$@" > /dev/null 2>&1) && echo yes || echo no; }

ok "a well-formed request" "$(valid yo61/demo 12 "$SHA" "$SCRATCH/out")" "yes"
ok "repo without owner" "$(valid demo 12 "$SHA" "$SCRATCH/out")" "no"
ok "repo with a path traversal" "$(valid yo61/../etc 12 "$SHA" "$SCRATCH/out")" "no"
ok "repo with a flag-shaped name" "$(valid -x/demo 12 "$SHA" "$SCRATCH/out")" "no"
ok "PR number not numeric" "$(valid yo61/demo 12a "$SHA" "$SCRATCH/out")" "no"
ok "PR number zero" "$(valid yo61/demo 0 "$SHA" "$SCRATCH/out")" "no"
ok "abbreviated SHA" "$(valid yo61/demo 12 0123456 "$SCRATCH/out")" "no"
ok "uppercase SHA" "$(valid yo61/demo 12 "${SHA^^}" "$SCRATCH/out")" "no"
ok "missing output dir" "$(valid yo61/demo 12 "$SHA" "")" "no"
ok "too few arguments" "$(valid yo61/demo 12)" "no"

echo "--- parse_dep_options ---"
parsed() {
  (
    unset LASTLIGHT_REVIEW_MODEL
    parse_dep_options "$@" > /dev/null 2>&1
    printf 'model=%s rest=%s' "$MODEL" "${REST[*]}"
  )
}
ok "default model" "$(parsed a/b 1 "$SHA" out)" "model=sonnet rest=a/b 1 $SHA out"
ok "--model before positionals" "$(parsed --model opus a/b 1 "$SHA" out)" "model=opus rest=a/b 1 $SHA out"
ok "--model after positionals" "$(parsed a/b 1 "$SHA" out --model opus)" "model=opus rest=a/b 1 $SHA out"
ok "an unknown flag is refused" \
  "$( (parse_dep_options --bogus a/b > /dev/null 2>&1) && echo accepted || echo refused)" "refused"

# ── the head SHA must not move under the review ──────────────────────────
echo "--- head_matches ---"
printf '{"headRefOid":"%s"}' "$SHA" > "$SCRATCH/meta-same.json"
printf '{"headRefOid":"%s"}' "$OTHER" > "$SCRATCH/meta-moved.json"
printf '{}' > "$SCRATCH/meta-empty.json"
matches() { (head_matches "$1" "$SHA" > /dev/null 2>&1) && echo yes || echo no; }
ok "head still at the requested SHA" "$(matches "$SCRATCH/meta-same.json")" "yes"
ok "head moved since the sweep" "$(matches "$SCRATCH/meta-moved.json")" "no"
ok "metadata without a head" "$(matches "$SCRATCH/meta-empty.json")" "no"

# ── verdict validation: what may cross back out of the sandbox ──────────
echo "--- verdict_valid ---"
verdict() {
  jq -n --arg v "$1" --arg sha "$2" \
    '{verdict:$v, headSha:$sha, package:"tempo", from:"3.2.0", to:"3.2.1",
      updateType:"patch", summary:"s", reasons:["r"], humanChecks:[]}'
}
checked() { (verdict_valid "$1" "$SHA" > /dev/null 2>&1) && echo valid || echo invalid; }

verdict pass "$SHA" > "$SCRATCH/v1.json"
ok "a pass for the reviewed SHA" "$(checked "$SCRATCH/v1.json")" "valid"
verdict needs-human "$SHA" > "$SCRATCH/v2.json"
ok "needs-human is a verdict" "$(checked "$SCRATCH/v2.json")" "valid"
verdict fail "$SHA" > "$SCRATCH/v3.json"
ok "fail is a verdict" "$(checked "$SCRATCH/v3.json")" "valid"
verdict approve "$SHA" > "$SCRATCH/v4.json"
ok "an unknown verdict word" "$(checked "$SCRATCH/v4.json")" "invalid"
verdict pass "$OTHER" > "$SCRATCH/v5.json"
ok "a pass for a different SHA" "$(checked "$SCRATCH/v5.json")" "invalid"
jq 'del(.reasons)' "$SCRATCH/v1.json" > "$SCRATCH/v6.json"
ok "reasons missing" "$(checked "$SCRATCH/v6.json")" "invalid"
jq '.humanChecks = "none"' "$SCRATCH/v1.json" > "$SCRATCH/v7.json"
ok "humanChecks not an array" "$(checked "$SCRATCH/v7.json")" "invalid"
jq '.humanChecks = ["read the release notes"]' "$SCRATCH/v1.json" > "$SCRATCH/v8.json"
ok "a pass that still lists human checks" "$(checked "$SCRATCH/v8.json")" "invalid"
printf 'not json' > "$SCRATCH/v9.json"
ok "not JSON at all" "$(checked "$SCRATCH/v9.json")" "invalid"

# ── the prompt ───────────────────────────────────────────────────────────
echo "--- dependency_prompt ---"
P=$(dependency_prompt /ws "$SHA" yo61/demo 12)
has() { [[ $P == *"$1"* ]] && echo yes || echo no; }
ok "names the reviewed SHA" "$(has "$SHA")" "yes"
ok "names the PR" "$(has "yo61/demo#12")" "yes"
ok "marks the PR body untrusted" "$(has "UNTRUSTED")" "yes"
ok "points at the staged body" "$(has "$INPUT_DIR/pr-body.md")" "yes"
ok "points at the staged diff" "$(has "$INPUT_DIR/pr.diff")" "yes"
ok "asks for the Renovate config notes" "$(has "prBodyNotes")" "yes"
ok "names the output file" "$(has "$OUT_DIR/findings.json")" "yes"
ok "offers needs-human" "$(has "needs-human")" "yes"

# ── attestation ──────────────────────────────────────────────────────────
echo "--- write_attestation ---"
printf 'diff' > "$SCRATCH/pr.diff"
printf 'body' > "$SCRATCH/pr-body.md"
ok "input_hash matches git's stdin hash" "$(input_hash "$SCRATCH/pr.diff")" \
  "$(git hash-object --stdin < "$SCRATCH/pr.diff")"
write_attestation "$SCRATCH/att.json" yo61/demo 12 "$SHA" "$OTHER" \
  "$(input_hash "$SCRATCH/pr.diff")" "$(input_hash "$SCRATCH/pr-body.md")" sonnet
ok "binds the SHA" "$(jq -r .sha "$SCRATCH/att.json")" "$SHA"
ok "binds the base" "$(jq -r .base "$SCRATCH/att.json")" "$OTHER"
ok "records the diff hash it was given" "$(jq -r .diffHash "$SCRATCH/att.json")" \
  "$(git hash-object --stdin < "$SCRATCH/pr.diff")"
ok "records the body hash it was given" "$(jq -r .bodyHash "$SCRATCH/att.json")" \
  "$(git hash-object --stdin < "$SCRATCH/pr-body.md")"

echo "--- inputs are hashed before the reviewer can touch them ---"
MAIN=$(declare -f main)
before_reviewer() {
  local head=${MAIN%%run_reviewer*}
  [[ $head != "$MAIN" && $head == *"$1"* ]] && echo yes || echo no
}
# shellcheck disable=SC2016  # matched against main's source text, so it must not expand
ok "the diff is hashed before run_reviewer" "$(before_reviewer 'input_hash "$ws/$INPUT_DIR/pr.diff"')" "yes"
# shellcheck disable=SC2016  # matched against main's source text, so it must not expand
ok "the body is hashed before run_reviewer" \
  "$(before_reviewer 'input_hash "$ws/$INPUT_DIR/pr-body.md"')" "yes"
# shellcheck disable=SC2016  # matched against main's source text, so it must not expand
ok "nothing re-reads the workspace inputs after the review" \
  "$(
    after=${MAIN#*run_reviewer}
    [[ $after == *'$INPUT_DIR'* ]] && echo yes || echo no
  )" "no"
ok "records the posture" "$(jq -r .isolation "$SCRATCH/att.json")" "sandboxed"
ok "records the runner" "$(jq -r .runner "$SCRATCH/att.json")" "dependency-review"

# ── sourcing must not start a review ─────────────────────────────────────
echo "--- sourcing guard ---"
ok "sourcing ran nothing" "$(bash -c "source '$DEP'; echo loaded" 2>&1 | tail -1)" "loaded"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
