#!/usr/bin/env bash
# Run the Last Light PR review as an INDEPENDENT pass, in a fresh headless
# Claude session that did not write the code.
#
# WHY THIS EXISTS
#   The recorder alone cannot tell a real review from a hand-written
#   findings.json: it validates the schema and the pass bar, nothing else. An
#   agent reviewing its own work is exactly where that fails -- measured on
#   github-repos#82, a self-review missed a Critical that the server's review
#   caught. So the review is run by a separate `claude -p` session with no
#   memory of authoring the change, which is the property that makes the
#   server's review useful in the first place.
#
# WHAT IT DOES NOT FIX
#   This raises the bar; it does not make forgery impossible. Anyone who can
#   write findings.json can also write the attestation beside it. The point is
#   that the honest path is now also the easy path, and that a review is bound
#   to the exact diff it looked at.
#
# ISOLATION -- the reviewed diff is UNTRUSTED INPUT
#   The prompt tells this session the code is not its own and not to be trusted,
#   which makes the diff an injection surface. It runs unattended from a push.
#
#   So the review happens in a DISPOSABLE CLONE under an OS sandbox; see
#   lastlight-sandbox.sh for the policy, the verified controls and the reason
#   `--no-hardlinks` is load-bearing. Because the sandbox bounds the blast
#   radius structurally, the reviewer gets Bash and can run PROBES -- installing
#   a dependency, executing a test -- which the skill permits and which caught
#   the one bypass repeated static reading had missed.
#
#   `LASTLIGHT_REVIEW_SANDBOX=off`, or a platform with no sandbox available,
#   degrades to the earlier posture: a read-only tool list, no probes, writes
#   scoped to the single findings.json path, and a printed warning. That is a
#   weaker review, not an equivalent one -- findings then rest on reading rather
#   than execution -- so the attestation records which posture produced it.
#
# Usage:
#   lastlight-review-run.sh [--model <m>] [base-ref]   # base: merge-base with origin/HEAD
#
# Env:
#   LASTLIGHT_REVIEW_MODEL    model for the reviewer (default: sonnet, matching
#                             Last Light's own models.default). Also --model <m>.
#   LASTLIGHT_REVIEW_TIMEOUT  seconds (default 900)
#   LASTLIGHT_REVIEW_TOOLS    override the allowed-tools list
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SELF_DIR
readonly ASSETS="${LASTLIGHT_REVIEW_DIR:-$HOME/.claude/lastlight-review}"
# shellcheck source=scripts/lastlight-sandbox.sh
source "$SELF_DIR/lastlight-sandbox.sh"
readonly OUT_DIR=.lastlight/pr-review
readonly TIMEOUT="${LASTLIGHT_REVIEW_TIMEOUT:-900}"
# Read-only exploration plus the one Write the skill's contract requires.
# An ARRAY, not a string: these contain spaces and parentheses, so a word-split
# string turns `Bash(git diff:*)` into two malformed rules that the CLI ignores
# with a warning -- leaving the reviewer unable to run git at all.
# NOTE the absence of a bare `Write`: that would be an unscoped allow and would
# silently defeat the path-scoped rules `review_tools` appends. Writes must stay
# confined to the one file the contract requires -- which is why the rules there
# name that path, and why both `Edit` and `Write` are needed for it.
readonly DEFAULT_TOOLS=(
  Read Grep Glob
  'Bash(git diff:*)' 'Bash(git log:*)' 'Bash(git show:*)'
  'Bash(git status:*)' 'Bash(rg:*)' 'Bash(fd:*)'
)
# Matches Last Light's own `models.default` (anthropic/claude-sonnet-4-6), which
# is what its `review` phase falls back to when `models.review` is unset and
# analysis is disabled. Pinning the tier here rather than inheriting the CLI
# default keeps the local pass comparable to the server's -- and stops a review
# silently running on whatever model the invoking session happened to use.
readonly DEFAULT_MODEL=sonnet

die() {
  printf 'lastlight-review-run: %s\n' "$1" >&2
  exit 1
}

main() {
  command -v claude > /dev/null 2>&1 || die "the claude CLI is required"
  command -v jq > /dev/null 2>&1 || die "jq is required"
  # A timeout command bounds the reviewer session and the containment probe,
  # and macOS ships neither spelling of it. Undeclared, its absence was
  # swallowed by the probe's `|| true` and the run died blaming the model for
  # being unavailable.
  #
  # ASK THE RESOLVER, not `command -v` on a name nobody runs. The first version
  # of this check accepted `gtimeout` while every call site executed `timeout`,
  # so a machine carrying only the g-prefixed build passed the check and failed
  # every call -- a declaration that made the misdiagnosis harder to find
  # rather than easier.
  [[ -n $(sandbox_timeout_cmd) ]] \
    || die "no timeout command on PATH (looked for timeout and gtimeout). macOS ships neither; install GNU coreutils."

  # Model resolution, most specific first: --model flag, env, then the pinned
  # default. Recorded in the attestation so a review can always be traced to
  # the model that produced it.
  # Review uncommitted work instead of a committed diff. Advisory only: see
  # where the attestation is written for why it cannot satisfy the push gate.
  # A LOOP, not two positional tests. Checking each flag only in position one
  # meant `--model opus --working-tree` left the second flag sitting where the
  # base-ref argument is read, so the mode silently did not engage and the run
  # died complaining about a merge base instead. Order must not matter, and an
  # unknown flag must say so rather than be read as a ref.
  parse_options "$@"
  set -- ${REST[@]+"${REST[@]}"}
  readonly WORKING_TREE MODEL

  local root sha base
  root=$(git rev-parse --show-toplevel 2> /dev/null) || die "not inside a git repository"
  cd "$root"
  sha=$(git rev-parse HEAD)

  base=${1:-}
  if base_needed "$base" "$WORKING_TREE"; then
    local default_ref
    default_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null || true)
    [[ -n $default_ref ]] || default_ref=origin/main
    git rev-parse --verify --quiet "$default_ref" > /dev/null 2>&1 || default_ref=origin/master
    base=$(git merge-base HEAD "$default_ref" 2> /dev/null) \
      || die "could not find a merge base with ${default_ref}; pass a base ref explicitly"
  fi

  [[ -f "$ASSETS/skills/pr-review/SKILL.md" ]] \
    || die "review assets not staged -- run lastlight-review-sync.sh first"

  # FAIL FAST on a dirty tree. The recorder already refuses one, but only at the
  # very end -- so without this you pay for a full review before anything
  # objects, and the review you paid for was incoherent anyway: it diffs
  # `base...HEAD` (committed) while the reviewer reads files from the live
  # working tree (uncommitted). Checking here makes "reviews run against
  # committed code" true rather than true-by-convention.
  if [[ $WORKING_TREE -eq 0 && -n $(git status --porcelain -- "$LASTLIGHT_EXCLUDE") ]]; then
    die "the working tree has uncommitted changes outside .lastlight/. The diff under review is base...HEAD, but the reviewer reads the live tree, so the two would disagree. Commit or stash first, or pass --working-tree to review the uncommitted state itself."
  fi

  refuse_symlinked_outputs "$root"
  mkdir -p "$OUT_DIR"

  # Three-dot: what this branch adds, not what main did meanwhile (SKILL.md §3).
  # In working-tree mode the subject is instead everything not yet committed,
  # tracked and untracked alike.
  if [[ $WORKING_TREE -eq 1 ]]; then
    base=HEAD
    working_tree_diff > "$OUT_DIR/diff.patch"
  else
    git diff "$base"...HEAD > "$OUT_DIR/diff.patch"
  fi
  if [[ ! -s "$OUT_DIR/diff.patch" ]]; then
    die "empty diff against ${base:0:12} -- nothing to review"
  fi
  local diff_hash
  # --stdin, to match what the recorder recomputes. `git hash-object <path>`
  # applies the clean filter for that path, so with core.autocrlf on a patch
  # containing CRLF hashes differently from the same bytes on stdin -- and the
  # recorder uses stdin. A freshly-run review of exactly the right diff was then
  # rejected as not matching itself, on every push touching such a file.
  diff_hash=$(git hash-object --stdin < "$OUT_DIR/diff.patch")

  # A stale findings.json would bias an "independent" pass, and the skill is
  # explicit that a finding copied from another stage is one the adjudicator can
  # no longer cross-check. Start clean.
  rm -f "$OUT_DIR/findings.json" "$OUT_DIR/attestation.json"

  # ── Isolation ────────────────────────────────────────────────────────────
  # Sandboxed by default. The reviewer works on a disposable clone under an OS
  # sandbox, which is what makes PROBES safe -- and probes are what caught the
  # one bypass that repeated static review missed.
  local workspace="" settings_file="" review_root=$root assets_root=$ASSETS
  local -a extra_args=()
  if [[ ${LASTLIGHT_REVIEW_SANDBOX:-on} != off ]] && sandbox_supported; then
    if [[ $WORKING_TREE -eq 1 ]]; then
      workspace=$(sandbox_make_working_workspace "$root")
    else
      workspace=$(sandbox_make_workspace "$root" "$sha")
    fi
    review_root=$workspace
    # BEFORE anything is written into the clone. Everything below writes from
    # this process, outside the sandbox, with the user's privileges, at names
    # the reviewed branch is free to have committed -- as a symlink, pointing
    # anywhere.
    sandbox_clear_runner_paths "$workspace"
    settings_file="$workspace/.lastlight-sandbox.json"
    mkdir -p "$workspace/$OUT_DIR"
    sandbox_settings_json "$workspace" > "$settings_file"
    extra_args=(--settings "$settings_file")
    # shellcheck disable=SC2064  # expand now, not at trap time
    trap "rm -rf '$(dirname "$workspace")'" EXIT
    cp "$OUT_DIR/diff.patch" "$workspace/$OUT_DIR/diff.patch"
    # Staged, not referenced in place: reads are scoped to the workspace, so
    # anything the reviewer needs has to be inside it.
    sandbox_stage_assets "$ASSETS" "$workspace"
    assets_root="$workspace/.lastlight-assets"

    # PROVE it before trusting it. A settings file that fails validation is
    # silently ignored in -p mode, which would leave a reviewer holding
    # unrestricted Bash with no confinement at all. Never infer the sandbox
    # from having asked for it.
    local verify_rc=0
    sandbox_verify "$settings_file" "$workspace" || verify_rc=$?
    case $verify_rc in
      0) printf '  isolated workspace: %s (containment verified, probes enabled)\n' "$workspace" >&2 ;;
      2) die "could not tell whether the sandbox engaged: the containment probe did not complete, so there is no evidence either way. Common causes are the model being unavailable -- a session limit, an auth failure, a timeout -- and a policy that denies the probe its own workspace. ${OUT_DIR}/reviewer.log, if it has anything in it, says which. Refusing to guess. Re-run, or use LASTLIGHT_REVIEW_SANDBOX=off for a read-only review." ;;
      *) die "the sandbox did not engage -- a canary escaped the workspace. Refusing to run a probe-enabled review unconfined. Re-run with LASTLIGHT_REVIEW_SANDBOX=off for a read-only review." ;;
    esac
  else
    # STILL DENY THE READS. Without a settings file the reviewer keeps the Read
    # tool and no permissions.deny, so a prompt injection in the diff could read
    # anything the user can and copy it into findings.json -- the artifact
    # carried back out. "No Bash" is not containment; the sandboxed path has
    # denied this since read_deny_rules existed and this branch had not.
    settings_file=$(mktemp -t lastlight-review-deny)
    # shellcheck disable=SC2064  # expand now, not at trap time
    trap "rm -f '$settings_file'" EXIT
    sandbox_read_deny_settings_json > "$settings_file"
    extra_args=(--settings "$settings_file")

    printf '  NOT SANDBOXED -- read-only review, no probes.\n' >&2
    printf '  Host reads are still denied; what is missing is the OS sandbox, so\n' >&2
    printf '  nothing confines a spawned process -- which is why Bash is withheld.\n' >&2
  fi

  review_tools "$workspace"
  local -a tools=("${REVIEW_TOOLS[@]}")

  printf 'Reviewing %s against %s\n  model: %s (independent session)\n' \
    "${sha:0:12}" "${base:0:12}" "$MODEL" >&2

  # Only when sandboxed. Unsandboxed the reviewer runs with the user's own
  # privileges anyway, so an explicit environment would be theatre -- and the
  # git settings would take the user's own gitignore away for no gain.
  #
  # `-i` first: the reviewer gets the keep-list and nothing else, so an
  # exported GITHUB_TOKEN is not sitting one `printenv` away from a diff that
  # is untrusted by this script's own doctrine, with github egress open.
  local -a env_args=()
  if [[ -n $workspace ]]; then
    env_args=(-i)
    while IFS= read -r kv; do env_args+=("$kv"); done < <(sandbox_reviewer_env)
    while IFS= read -r kv; do env_args+=("$kv"); done < <(reviewer_git_env)
    # LAST, so it overrides the TMPDIR/TMP/TEMP the keep-list carried through.
    # The policy grants the per-review scratch directory and not the shared
    # root, so a child still pointed at the root could not write a temp file.
    while IFS= read -r kv; do env_args+=("$kv"); done < <(sandbox_scratch_env "$workspace")
  fi

  local rc=0
  (cd "$review_root" && env "${env_args[@]+"${env_args[@]}"}" "$(sandbox_timeout_cmd)" "$TIMEOUT" claude -p "$(prompt "$review_root" "$base" "$sha" "$assets_root")" \
    --allowed-tools "${tools[@]}" \
    "${extra_args[@]}" \
    --model "$MODEL") > "$OUT_DIR/reviewer.log" 2>&1 || rc=$?
  # A rule the CLI could not parse leaves the reviewer without a tool it needed,
  # and it carries on and produces a thinner review rather than failing. Treat
  # that as a hard error: a silently under-equipped reviewer is worse than none.
  #
  # Checked BEFORE the exit status, not after. It used to come after, so a run
  # that was also killed at the timeout died pointing at the timeout while the
  # rejected rule went unmentioned -- and the rejection is the better
  # explanation whatever the status turned out to be.
  if tool_rule_rejected "$OUT_DIR/reviewer.log"; then
    die "the CLI rejected an allowed-tools rule, so the reviewer ran under-equipped; see $OUT_DIR/reviewer.log"
  fi
  if [[ $rc -eq 124 ]]; then
    die "$(timeout_message "$OUT_DIR/reviewer.log" "$TIMEOUT")"
  fi
  if [[ $rc -ne 0 ]]; then
    [[ -s "$OUT_DIR/reviewer.log" ]] \
      || die "the reviewer session failed (exit ${rc}) without writing anything to ${OUT_DIR}/reviewer.log."
    die "the reviewer session failed (exit ${rc}); see $OUT_DIR/reviewer.log"
  fi

  # The reviewer wrote inside the isolated workspace; bring the one artifact
  # the contract produces back out. Nothing else crosses the boundary.
  if [[ -n $workspace ]] && [[ -e "$workspace/$OUT_DIR/findings.json" || -L "$workspace/$OUT_DIR/findings.json" ]]; then
    findings_contained "$workspace" \
      || die "the reviewer left something other than a plain file where its findings should be, in $workspace/$OUT_DIR. Refusing to copy it out: this step runs outside the sandbox and would read whatever that path points at."
    copy_findings_out "$workspace/$OUT_DIR/findings.json" "$OUT_DIR/findings.json" \
      || die "the findings file became a symlink while it was being copied out of the sandbox, so something was still running in there. Nothing was read through it. Re-run the review."
  fi
  [[ -f "$OUT_DIR/findings.json" ]] \
    || die "the reviewer wrote no findings.json; see $OUT_DIR/reviewer.log"
  jq -e . "$OUT_DIR/findings.json" > /dev/null 2>&1 \
    || die "the reviewer wrote invalid JSON to findings.json"

  # Syntax was the ONLY thing checked here, and the schema carries a `skip`
  # flag for conditions that belong to the GitHub flow -- bot-authored,
  # already merged, already reviewed -- none of which a local base..HEAD run
  # can be in. Refusing it matters because of what this script says about its
  # own input at the top: the diff is untrusted, and it is read by the session
  # writing this file. A diff that talks the reviewer into skipping otherwise
  # earns a correctly-computed attestation for a review that never ran.
  if [[ $(findings_skipped "$OUT_DIR/findings.json") == yes ]]; then
    die "the reviewer set \`skip\`, which no local review can be eligible for -- so nothing was reviewed. See $OUT_DIR/reviewer.log"
  fi

  # Binds the review to the exact diff it saw. The recorder refuses a marker
  # whose attestation does not match the current HEAD and diff.
  #
  # A working-tree review deliberately records sha:"" -- there is no commit it
  # could honestly vouch for, and the recorder compares this against HEAD. That
  # mismatch is the point: a pre-commit check is ADVISORY and must never be
  # able to satisfy the push gate. Fail-safe by construction rather than by a
  # rule someone has to remember.
  jq -n \
    --arg sha "$([[ $WORKING_TREE -eq 1 ]] && echo "" || echo "$sha")" \
    --arg base "$base" \
    --arg diff "$diff_hash" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg model "$MODEL" \
    --arg iso "$([[ -n $workspace ]] && echo sandboxed || echo unsandboxed)" \
    --arg mode "$([[ $WORKING_TREE -eq 1 ]] && echo working-tree || echo committed)" \
    '{sha:$sha, base:$base, diffHash:$diff, reviewedAt:$at, runner:"independent-session", model:$model, isolation:$iso, mode:$mode}' \
    > "$OUT_DIR/attestation.json"

  printf 'Review complete: event=%s findings=%s\n' \
    "$(jq -r '.event // "?"' "$OUT_DIR/findings.json")" \
    "$(jq -r '(.findings // []) | length' "$OUT_DIR/findings.json")" >&2
  printf 'Next: %s/lastlight-review-record.sh\n' "$SELF_DIR" >&2
}

# The reviewer's tool allowlist, in REVIEW_TOOLS. A function because it is the
# only thing standing between the reviewer and the rest of the machine when
# there is no sandbox, and inline in main() it could not be asserted on.
#
# Takes the workspace path, empty when unsandboxed.
# Whether a base ref has to be resolved from the remote at all.
#
# NOT in working-tree mode, which discards the value for HEAD immediately
# after. Resolving first meant a repository with no reachable origin/main or
# origin/master could not use `--working-tree`: it died on the merge base
# before the flag was ever honoured -- and that is the usage the README
# documents, with no base ref given. A fresh `git init` with no remote is the
# ordinary case for it.
#
# A function so the decision can be asserted on. main() reaches the network and
# starts a review, so nothing in the suite calls it, and this branch shipped
# with no coverage.
# Everything not yet committed, tracked and untracked alike, on stdout.
#
# `.lastlight/` is excluded from BOTH halves, and the untracked half is why.
# The caller redirects this into .lastlight/pr-review/diff.patch, and a redirect
# creates its target before the command runs -- so by the time
# `git ls-files --others` executes, the output file already exists as an
# untracked file and lists itself. The diff then embeds a copy of whatever has
# been written to it so far.
#
# It does not show up on a machine whose global gitignore happens to cover
# `.lastlight/`, which is why it survived here: `--exclude-standard` reads that
# file, so the bug is invisible to the author and present for everyone else --
# including the sandboxed reviewer, which cannot read $HOME at all.
#
# The same `:(exclude)` pathspec as the dirty-tree check above, for the same
# reason: the tool's own workspace is not part of the change under review.
# Whether the CLI rejected an allowed-tools rule, which leaves the reviewer
# without a tool it asked for.
#
# `grep`, not `rg`. This script requires only claude and jq, and on a machine
# without ripgrep `rg` exits 127 -- the `if` body is skipped, the hard error
# never fires, and a reviewer that ran under-equipped still writes an
# attestation that unblocks the push. A safety check that vanishes when an
# undeclared tool is missing is worse than no check, because it reads as having
# passed.
# The reviewer's artifact, but only if it is genuinely a file the reviewer
# created inside the sandbox.
#
# The copy-back in `main` runs in THIS process -- outside the sandbox, with the
# user's own privileges -- and `cp` follows symlinks. The reviewer holds Bash
# inside the workspace, and a symlink is a write to a path it is allowed to
# write, so
#
#     ln -sf ~/.claude/.credentials.json .lastlight/pr-review/findings.json
#
# makes this process read the file the sandbox exists to keep it away from and
# deposit it in the real repository. `[[ -f ]]` does not catch it: only `-L`
# does not follow a link. Nor does the `jq -e` check downstream -- credentials
# are valid JSON. The diff being reviewed is untrusted input by this script's
# own doctrine, so this is reachable without anyone acting in bad faith
# locally.
#
# Three properties, each true of any file the reviewer actually wrote:
#   - the path is not itself a symlink;
#   - its directory resolves inside the workspace -- .lastlight/ can be a link
#     too, which puts a real file at a real path outside;
#   - it has one link. A hardlink shares content without being a symlink;
#     whether the sandbox refuses to create one against a denied source is not
#     something I could test from here, and refusing costs nothing.
#
# `find`, not `stat`, whose flags differ between BSD and GNU in a way that has
# already produced a wrong answer here -- and `-links 1`, which makes find say
# the file is unshared, rather than `-links +1`, which makes it say the file is
# shared. The difference is only in the failure case and it is the whole point:
# a find that did not run says nothing either way, and under `+1` that silence
# read as containment. Same shape as the missing `rg` in tests/lib.sh.
#
# Refuse rather than copy carefully: nothing legitimate needs the artifact to
# be anything but a plain file. The reviewer session has exited by now, so no
# one can swap the path between this check and the copy.
# Refuse to write through anything the branch committed at the runner's own
# paths, in the REAL repository.
#
# The workspace copy of this problem is handled by moving those names aside;
# that is wrong here, because this is the user's working tree and
# .lastlight/pr-review holds the artefacts of previous runs. So the targets are
# checked and a symlink is refused.
#
# It matters because these writes happen BEFORE any workspace exists: this
# process, outside any sandbox, with the user's privileges, on a checkout of
# the branch under review -- which this script's own doctrine calls untrusted
# input. Reproduced before the fix: a file outside the repository was
# overwritten with the runner's own output.
refuse_symlinked_outputs() {
  local root=$1 p
  for p in ".lastlight" "$OUT_DIR"; do
    if [[ -L "$root/$p" ]]; then
      die "$root/$p is a symlink. This runner writes below it with your privileges, before any sandbox exists, so it will not follow it. Remove or replace it."
    fi
  done

  # Everything already in there, rather than a list of the names this runner
  # happens to write today. The first version enumerated them and missed
  # reviewer.log; a list is correct until someone adds a write.
  [[ -d "$root/$OUT_DIR" ]] || return 0
  local entry
  for entry in "$root/$OUT_DIR"/* "$root/$OUT_DIR"/.[!.]*; do
    [[ -e $entry || -L $entry ]] || continue
    if [[ -L $entry ]]; then
      die "$entry is a symlink. This runner writes there with your privileges, before any sandbox exists, so it will not follow it. Remove or replace it."
    fi
  done
}

findings_contained() {
  local ws=$1 path=$1/$OUT_DIR/findings.json dir root

  [[ ! -L $path && -f $path ]] || return 1
  dir=$(cd -P "$ws/$OUT_DIR" 2> /dev/null && pwd -P) || return 1
  root=$(cd -P "$ws" 2> /dev/null && pwd -P) || return 1
  [[ $dir == "$root" || $dir == "$root"/* ]] || return 1
  [[ -n $(find "$path" -links 1 2> /dev/null) ]]
}

# Environment for the reviewer's git, when the review is sandboxed.
#
# The sandbox denies reads across $HOME as a whole, and git looks for four
# things there: the global config, the system config, and -- independently of
# where config lives -- $XDG_CONFIG_HOME/git/{ignore,attributes}. Each denied
# lookup prints `warning: unable to access ...: Permission denied`, twice per
# `git status`, on the stderr the reviewer reads.
#
# Measured, because the obvious answer is wrong: git is NOT fatal here. Every
# command exits 0 and produces correct output with $HOME entirely untraversable
# (git 2.55). And GIT_CONFIG_GLOBAL plus GIT_CONFIG_NOSYSTEM, which is the pair
# that looks like the fix, silences none of it -- the warnings come from the
# excludes and attributes paths, which are resolved separately. It takes all
# four to get a clean stderr.
#
# Scoped to the sandboxed run and set on that command alone, never exported:
# this process computes the attestation's diff hash with `git hash-object`,
# which applies the clean filter, and core.attributesFile is what selects it.
# Changing it here would change the hash the recorder checks.
reviewer_git_env() {
  printf '%s\n' \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0=/dev/null \
    GIT_CONFIG_KEY_1=core.attributesFile GIT_CONFIG_VALUE_1=/dev/null
}

# Whether the CLI refused one of the rules it was handed.
#
# Two wordings, because this matches a message rather than a status and the
# message has already changed once. The pattern only knew the older
# "Ignoring --allowedTools rule", so when the CLI moved to "Permission allow
# rule (--allowed-tools): ... is not matched" the guard went quiet and a
# rejected rule rode through unreported. Matching both is the cost of having no
# machine-readable signal to check instead.
# Whether the reviewer marked the review skipped.
#
# Extracted so it can be tested: the check it replaces sat inline in a function
# that runs a model session, which is not something a suite can call.
# Bring the one artefact the contract produces out of the sandbox.
#
# -P: never follow a link. The containment check and this copy are separate
# operations with a gap between them, and the reviewer had Bash -- nothing here
# waits for whatever it may have left running. A process that swaps the file
# for a symlink in that window handed `cp` a host file to read, and its
# contents landed in the real repository as tracked output: exactly what the
# check before this was written to prevent.
#
# The race is still there; bash cannot copy through a descriptor. What changes
# is where it ends. Copying the LINK means the worst case is a symlink arriving
# here, which is refused and removed -- so the bytes on the far side of it are
# never read by anything outside the sandbox.
copy_findings_out() {
  local src=$1 dest=$2
  cp -P "$src" "$dest" || return 1
  if [[ -L $dest ]]; then
    rm -f "$dest"
    return 1
  fi
  return 0
}

findings_skipped() {
  if [[ $(jq -r '.skip // false' "$1" 2> /dev/null) == true ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

tool_rule_rejected() {
  grep -qE 'Ignoring --allowedTools rule|Permission (allow|deny) rule \(--[a-z-]+\):.*not matched' \
    "$1" 2> /dev/null
}

# What to say when the session was killed at the timeout.
#
# It used to state flatly that the log was empty, reasoning that SIGTERM
# flushes nothing. That is wrong: the CLI writes startup diagnostics long
# before the kill. A run that timed out with a rejected tool rule in the log
# was told to raise LASTLIGHT_REVIEW_TIMEOUT -- the wrong next step -- while
# the reason sat in the file the message had just called empty.
timeout_message() {
  local log=$1 secs=$2
  if [[ -s $log ]]; then
    printf 'the reviewer session was killed at the %ss timeout. %s holds what it wrote before the kill and may say why; read that before raising LASTLIGHT_REVIEW_TIMEOUT.' \
      "$secs" "$log"
  else
    printf 'the reviewer session was killed at the %ss timeout, and %s is empty. Re-run it, or raise LASTLIGHT_REVIEW_TIMEOUT.' \
      "$secs" "$log"
  fi
}

working_tree_diff() {
  git diff HEAD -- "$LASTLIGHT_EXCLUDE"
  git ls-files --others --exclude-standard -z -- "$LASTLIGHT_EXCLUDE" \
    | xargs -0 -I{} git diff --no-index -- /dev/null {} 2> /dev/null || true
}

base_needed() {
  local given=$1 working_tree=$2
  [[ -z $given && $working_tree -eq 0 ]]
}

review_tools() {
  local workspace=${1:-}

  REVIEW_TOOLS=("${DEFAULT_TOOLS[@]}")
  if [[ -n ${LASTLIGHT_REVIEW_TOOLS:-} ]]; then
    IFS=',' read -r -a REVIEW_TOOLS <<< "$LASTLIGHT_REVIEW_TOOLS"
  fi

  # Sandboxed, the tool allowlist stops being the security boundary -- the
  # sandbox is -- so the reviewer gets Bash and can run things. Unsandboxed it
  # stays the narrow read-only list, because then it IS the only boundary.
  #
  # An explicit LASTLIGHT_REVIEW_TOOLS still wins. Widening happened
  # unconditionally when sandboxed, which is the default on any machine with a
  # sandbox available -- so the documented override was discarded in the common
  # case, without a word, including when it was set to NARROW the reviewer.
  if [[ -n $workspace && -z ${LASTLIGHT_REVIEW_TOOLS:-} ]]; then
    REVIEW_TOOLS=(Read Grep Glob Bash)
  fi

  # The ONE write the contract needs, scoped to exactly that path. Appended
  # after any override so widening the tool list cannot accidentally drop the
  # reviewer's ability to record its own result.
  #
  # BOTH verbs, and that is not belt-and-braces. The run deletes any stale
  # findings.json before starting, so the file is guaranteed ABSENT -- and
  # `Edit` cannot create a file. With `Edit` alone the reviewer stalls asking
  # for permission and the run dies having already spent the model call. It
  # only ever succeeded when the reviewer improvised with `Bash`, which the
  # unsandboxed list does not grant at all, so the failure was a coin toss
  # decided by which tool the reviewer happened to reach for. Scoped to the
  # path either way: a bare `Write` would let it edit the code under review,
  # including these scripts.
  #
  # RELATIVE, and main() has already cd'd to $root. A bare absolute path does
  # NOT match (verified: the reviewer was then unable to write its own findings,
  # which would have failed every run closed); the absolute form needs a `//`
  # prefix. The relative form sidesteps that entirely.
  #
  # The PROMPT names the same relative path, and must keep doing so. It asked
  # for an absolute one, which this rule does not match -- survivable while
  # sandboxed, because Bash is granted there and the reviewer could write the
  # file another way, and fatal in the unsandboxed fallback, where the tool list
  # is the whole boundary and this rule is the only way through.
  #
  # Edit, and ONLY Edit. A path rule is matched against file permission checks,
  # and those recognise Edit(path) alone -- an Edit rule covers every
  # file-editing tool, Write included. A Write(path) rule beside it is not a
  # belt-and-braces second grant: the CLI rejects it outright, which is the
  # under-equipped-reviewer case this script treats as fatal, tripped by the
  # script itself.
  REVIEW_TOOLS+=("Edit(${OUT_DIR}/findings.json)")
}

usage() {
  # ${BASH_SOURCE[0]}, not $0: this is the file the header lives in, which is
  # true whether the script was executed or sourced. Reading $0 printed nothing
  # at all when a caller sourced the file and asked for help.
  sed -n '2,45p' "${BASH_SOURCE[0]}"
  exit 0
}

# Read the options, leaving any remaining arguments in REST.
#
# Extracted so it can be tested. Two bugs lived here and were each found by
# hand: checking flags only in position one, so `--model x --working-tree` left
# the second flag in the base-ref slot; and matching only `--*`, so a bare `-h`
# fell through to be read as a git ref. Neither would have survived a test, and
# neither had one.
#
# WORKING_TREE, MODEL and REST are set for the caller rather than returned,
# because a function can return only a status and these are three values.
parse_options() {
  WORKING_TREE=0
  MODEL=${LASTLIGHT_REVIEW_MODEL:-$DEFAULT_MODEL}
  # Any leading `-`, not just `--`. Refs do not begin with one, so an
  # unrecognised flag belongs in `*)` rather than being read as a base ref.
  #
  # The WHOLE argument list, not a leading run of flags. Stopping at the first
  # non-flag left `origin/main --working-tree` with the flag unparsed in REST:
  # WORKING_TREE stayed 0, the refusal below never fired, and the run reviewed
  # the committed diff and exited 0 -- the silent reinterpretation that refusal
  # exists to prevent, avoided only by writing the flags first.
  local -a rest=()
  while [[ $# -gt 0 ]]; do
    if [[ $1 != -* ]]; then
      rest+=("$1")
      shift
      continue
    fi
    case $1 in
      --working-tree)
        WORKING_TREE=1
        shift
        ;;
      --model)
        [[ -n ${2:-} ]] || die "--model needs a value"
        MODEL=$2
        shift 2
        ;;
      --help | -h)
        usage
        ;;
      *) die "unknown option: $1" ;;
    esac
  done
  REST=("${rest[@]+"${rest[@]}"}")

  # The two say different things about what to review, and `main` resolves that
  # by overwriting the base with HEAD -- so the run reviewed only uncommitted
  # work, exited 0, and reported success while the caller believed everything
  # since the ref they named had been covered. Committed branch work simply was
  # not looked at. Refuse instead: this script already holds that unsupported
  # input must say so rather than be quietly reinterpreted.
  if [[ $WORKING_TREE -eq 1 && ${#REST[@]} -gt 0 ]]; then
    die "--working-tree reviews what is not yet committed, so there is nothing to compare against a base ref -- but '${REST[0]}' was given as one. Pass one or the other: the ref alone reviews the branch, --working-tree alone reviews the uncommitted changes."
  fi
}

prompt() {
  local root=$1 base=$2 sha=$3 assets=$4
  cat << PROMPT
You are reviewing a pull request. You did NOT write this code — review it as an
independent reviewer would, and do not assume the author's reasoning was sound.

Follow the instructions in this skill file EXACTLY, including its findings
schema and its precision bar:

  ${assets}/skills/pr-review/SKILL.md
  ${assets}/skills/pr-review/references/findings-schema.md

Its companion skill, referenced by that file, is at:

  ${assets}/skills/code-review/SKILL.md

Context for the review:
  repository root : ${root}
  head SHA        : ${sha}
  base            : ${base}
  three-dot diff  : ${root}/${OUT_DIR}/diff.patch  (already generated)

Read the diff, then read the surrounding code in this checkout to judge it —
never assume a hunk is correct because it looks self-consistent.

Write your result to ${OUT_DIR}/findings.json -- that exact relative path,
from the repository root you are already in -- in the skill's schema
(skip? / summary / event / findings[]). An empty findings array is a valid
outcome when the falsifying looks came up empty — but it must be earned, not
assumed. Report Critical and Important findings only.

Do not post anything to GitHub. Do not modify any file other than
findings.json. You are the only reviewer; there is no later stage to catch what
you skip.
PROMPT
}

# Sourcing must not run anything. The test suite loads this file to exercise
# its parsing and tool-selection directly, and without the guard doing so
# started a real review -- which is exactly how it was discovered.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
