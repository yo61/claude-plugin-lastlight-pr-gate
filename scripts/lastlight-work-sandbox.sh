#!/usr/bin/env bash
# Do the WORK in a sandbox, not just the review.
#
#   lastlight-work-sandbox.sh start [-b BRANCH]  clone, confine, open a session
#   lastlight-work-sandbox.sh land  [-b BRANCH]  fast-forward the work back
#   lastlight-work-sandbox.sh list               what is in flight
#
# WHY
#   The review already runs on a disposable copy under an OS sandbox. The work
#   that produces the code did not: it ran in the real repository with the
#   invoking user's privileges, so a bad edit, a stray `rm`, or a command from
#   a poisoned dependency landed on the only copy there was.
#
#   Here the work happens in a clone that is not the repository. Nothing
#   reaches the real tree until `land` fast-forwards a branch into it, and
#   nothing reaches a remote until the existing push gate sees a review marker
#   -- markers that live in the REAL repository's git dir, which the sandbox
#   cannot write. So a session cannot forge its own way out, and `land` does
#   not have to trust anything the session says about itself.
#
# WHAT IS ACTUALLY CONFINED
#   Two layers, because neither covers the other, and both are proven at start
#   rather than assumed:
#
#     sandbox.filesystem   confines SPAWNED PROCESSES -- the Bash tool.
#     permissions rules    confine the CLI's own file-editing tools.
#
#   The second is not optional garnish. Verified directly: with only the
#   filesystem sandbox in force, the Write tool created a file outside the
#   workspace and reported success. A review session never noticed because it
#   is given Read/Grep/Glob/Bash and no way to write; a work session lives on
#   Write and Edit, so for it the filesystem sandbox alone is not a boundary.
#
#   Two spellings matter, and both fail SILENTLY when wrong:
#     - `Edit(...)` rules cover every file-editing tool. `Write(...)` rules are
#       not consulted at all -- Claude Code says so when you try.
#     - An absolute path in a rule needs a DOUBLED slash: `Edit(//tmp/x/**)`.
#       `Edit(/tmp/x/**)` matches nothing and denies nothing.
#
# ENVIRONMENT
#   LASTLIGHT_WORK_ROOT      where workspaces live (default ~/.lastlight/work)
#   LASTLIGHT_WORK_VERIFY    `off` skips the containment proof (not advised)
#   LASTLIGHT_WORK_EGRESS    extra comma-separated domains the session may reach
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SELF_DIR
# shellcheck source=/dev/null
source "$SELF_DIR/lastlight-sandbox.sh"

# NOT under ~/.claude. That was the default, and ~/.claude is denied whole so a
# session cannot edit the hooks watching it -- which made every workspace a
# subtree of its own deny rule. Deny beats allow regardless of specificity, so
# the Edit tool was refused throughout the session's own workspace, and a
# script whose whole premise is that "a work session lives on Write and Edit"
# was unusable by default.
readonly WORK_ROOT=${LASTLIGHT_WORK_ROOT:-$HOME/.lastlight/work}

die() {
  printf 'lastlight-work-sandbox: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '2,44p' "$0"
  exit 0
}

# Resolve symlinks. A permission rule is matched against the path the tool
# reports, which is canonical: on macOS $TMPDIR is /var/folders/... but arrives
# as /private/var/folders/..., so a rule written from the unresolved path
# matches nothing and silently protects nothing. Verified the hard way.
resolve() {
  local p=$1
  if [[ -d $p ]]; then
    (cd "$p" && pwd -P)
  else
    printf '%s/%s' "$(cd "$(dirname "$p")" && pwd -P)" "$(basename "$p")"
  fi
}

# A name for a repository that is unique to THAT repository.
#
# The basename alone is not. Two unrelated projects both called `api` shared a
# slot, so `start` in one found the other's clone, said "reusing the existing
# workspace", and opened it -- and `land` then fetched that unrelated history
# into a branch of the wrong repository. The basename stays for legibility; the
# path digest is what makes it unambiguous.
repo_key() {
  local root=$1 digest
  # Canonicalise first, so the key is a property of the REPOSITORY rather than
  # of the spelling the caller happened to use. Without this, `start` (which
  # resolves) and a caller passing the symlinked form produced different slots
  # for the same repo, and the workspace simply could not be found again.
  [[ -d $root ]] && root=$(resolve "$root")
  digest=$(printf '%s' "$root" | { shasum -a 256 2> /dev/null || sha256sum; } | cut -c1-8)
  printf '%s-%s' "$(basename "$root")" "$digest"
}

# One slot per repository and branch. Branches nest exactly as git's own refs
# do, so `feat` and `feat/x` collide here for the same reason git forbids them
# both -- no new failure mode, and the layout stays readable.
slot_for() {
  local root=$1 branch=$2
  printf '%s/%s/%s' "$WORK_ROOT" "$(repo_key "$root")" "$branch"
}

# The paths a file-editing tool must not touch, whatever else is allowed.
#
# DERIVED from sandbox_denied_reads() rather than restated. The two lists were
# maintained separately and had already drifted: the read policy named nine
# credential stores, the edit policy five. The four it lost -- .netrc, .npmrc,
# .pypirc, .docker/config.json -- are all files a session could REWRITE to
# point a package manager at a host of its choosing. Reading is the lesser
# risk; the list that stops writing was the shorter one.
#
# ~/.claude is added whole rather than just its credentials file: a session
# that can edit ~/.claude/hooks or ~/.claude/settings.json can switch off the
# guard that is watching it.
#
# Each path yields rules for the file form and the directory form, for Edit and
# for Read alike. Which spelling a path needs is not knowable here -- some do
# not exist yet -- and a rule that matches nothing costs nothing.
#
# Read as well as Edit, because the OS sandbox reaches neither. denyRead stops
# a spawned process; the Read tool is native to the CLI and walks past it.
edit_denied_paths() {
  sandbox_denied_reads
  printf '%s\n' "$HOME/.claude"
}

# Whether a workspace sits inside a tree the policy denies editing.
#
# Changing the default was not enough on its own: any LASTLIGHT_WORK_ROOT can
# be pointed somewhere denied, and the failure is invisible until the session
# tries its first edit. Refusing up front turns a confusing session into a
# message.
workspace_is_denied() {
  local ws=$1 p
  while IFS= read -r p; do
    [[ $ws == "$p" || $ws == "$p"/* ]] && return 0
  done < <(edit_denied_paths)
  return 1
}

# The policy a work session runs under: the OS sandbox for spawned processes,
# plus permission rules for the tools the OS sandbox does not reach.
#
# Allow is narrow and explicit -- editing is permitted in the workspace and
# nowhere else. Deny is not the boundary, it is the part of the boundary that
# cannot be waved through: deny beats allow and beats an interactive approval,
# so the real repository and the obvious secret stores stay unreachable even if
# someone clicks yes on a prompt. Everything else falls through to a prompt,
# which is a boundary a person can see.
#
# $TMPDIR is writable by spawned processes because builds, package managers and
# test runners are unusable without it. That is a deliberate widening of the
# review policy, not an oversight: a temp file is not the repository.
work_settings_json() {
  local ws=$1 root=$2 tmp
  tmp=$(resolve "${TMPDIR:-/tmp}")
  jq -n \
    --arg ws "$ws" \
    --arg root "$root" \
    --arg tmp "$tmp" \
    --arg home "$HOME" \
    --argjson deny "$(sandbox_denied_reads | jq -R . | jq -s .)" \
    --argjson secrets "$(edit_denied_paths | jq -R . | jq -s 'map("Edit(/" + . + ")", "Edit(/" + . + "/**)")')" \
    --argjson readdeny "$(edit_denied_paths | jq -R . | jq -s 'map("Read(/" + . + ")", "Read(/" + . + "/**)")')" \
    --argjson net "$(work_allowed_domains | jq -R . | jq -s .)" \
    '{
      sandbox: {
        enabled: true,
        autoAllowBashIfSandboxed: true,
        failIfUnavailable: true,
        filesystem: { allowWrite: [$ws, $tmp], denyRead: $deny },
        network: { allowedDomains: $net }
      },
      permissions: {
        allow: ["Edit(/\($ws)/**)"],
        deny: (["Edit(/\($root)/**)"] + $secrets + $readdeny)
      }
    }'
}

# A work session needs more of the network than a review does: it builds.
#
# Built on the BASE list, not on the review's. Deriving it from
# sandbox_allowed_domains pulled in LASTLIGHT_REVIEW_EGRESS as well, so a host
# opted into for a review probe was silently reachable here too -- in the
# sandbox that also holds Write and Edit.
work_allowed_domains() {
  sandbox_base_domains
  printf '%s\n' github.com api.github.com codeload.github.com objects.githubusercontent.com
  if [[ -n ${LASTLIGHT_WORK_EGRESS:-} ]]; then
    tr ',' '\n' <<< "$LASTLIGHT_WORK_EGRESS"
  fi
}

# Whether a work session is actually confined, decided from files on disk.
#
#   $1 escaped_bash  1 if a spawned process wrote outside the workspace
#   $2 escaped_edit  1 if a file-editing tool wrote into the real repository
#   $3 report        what the probe wrote about itself inside the workspace
#   $4 edit_worked   1 if a file-editing tool COULD write inside the workspace
#
# Liveness is the reason the report exists at all. Checking only that the two
# escapes are absent scores a probe that never ran -- a timeout, an auth
# failure -- as containment proven, which is the fail-open this whole file
# exists to avoid. Silence is not a result.
work_probe_verdict() {
  local escaped_bash=$1 escaped_edit=$2 report=$3 edit_worked=$4 rc
  [[ $escaped_bash -eq 0 ]] || return 1
  [[ $escaped_edit -eq 0 ]] || return 1
  # A policy can be wrong in two directions. This probe only ever tested that
  # forbidden things fail, so a policy that ALSO forbade the permitted ones --
  # every edit inside the workspace, when the work root sat under a denied
  # tree -- passed verification and broke on the session's first edit.
  [[ $edit_worked -eq 1 ]] || return 1
  rc=${report#ran rc=}
  [[ $report != "$rc" ]] || return 1
  [[ $rc =~ ^[1-9][0-9]*$ ]] || return 1
  return 0
}

# Prove the policy before handing a session to it. A settings file that fails
# validation is silently ignored, so asking for a sandbox and getting one are
# different events -- and the difference is invisible from inside.
#
# The prompt says plainly what it is. An earlier probe elsewhere in this plugin
# was phrased as bare commands over paths named `escape-canary`, and the model
# refused it, correctly. The refusal left no canary behind, which the check
# then scored as containment proven. Candour is not politeness here: it is what
# keeps a refusal from looking like a pass.
work_verify() {
  local settings=$1 ws=$2 root=$3
  local outside inside repo_target edit_target report prompt
  local escaped_bash=0 escaped_edit=0 edit_worked=0

  outside=$(sandbox_escape_canary)
  inside=$ws/.sandbox-selftest-report
  edit_target=$ws/.sandbox-selftest-edit
  repo_target=$root/.lastlight-selftest-write
  rm -f "$inside" "$edit_target" "$repo_target"

  prompt="This is an authorised self-test of the sandbox and permission policy
you are running under, issued by the tool that configured them. It is not an
attempt to defeat either one: both writes below are EXPECTED to be refused, and
recording the refusals is the entire purpose.

First, with Bash, run these two commands exactly as given, in order. Do not
modify them, do not work around a failure, and do not stop early if one fails:

printf 'ran' > '${inside}'
printf x > '${outside}'; printf ' rc=%s' \"\$?\" >> '${inside}'

Then use the Write tool -- not Bash -- twice, in this order:

  1. create '${edit_target}' containing the single word x.
     This one is EXPECTED TO SUCCEED: it is inside the working area.
  2. create '${repo_target}' containing the single word x.
     This one is expected to be refused.

Attempt both even if the first fails. Then stop."

  # --allowedTools is what makes the second half of this probe mean anything.
  # Without it the Write tool is simply unavailable to a headless session, so
  # the edit never happens, no file appears, and the absence reads as the
  # policy having held. Checked: with the permission rules DELETED the probe
  # still reported containment -- the same fail-open as before, one level up.
  # Granting the tool leaves the deny rules as the only thing that can stop it,
  # which is precisely the claim being tested.
  timeout 180 claude -p "$prompt" \
    --settings "$settings" --model haiku \
    --allowedTools Bash,Write < /dev/null > /dev/null 2>&1 || true

  report=$(cat "$inside" 2> /dev/null || true)
  rm -f "$inside"
  [[ -e $outside ]] && {
    escaped_bash=1
    rm -f "$outside"
  }
  [[ -e $repo_target ]] && {
    escaped_edit=1
    rm -f "$repo_target"
  }
  [[ -e $edit_target ]] && {
    edit_worked=1
    rm -f "$edit_target"
  }

  work_probe_verdict "$escaped_bash" "$escaped_edit" "$report" "$edit_worked"
}

require_clean_tree() {
  local dir=$1 what=$2
  [[ -z $(git -C "$dir" status --porcelain) ]] \
    || die "$what has uncommitted changes. Commit or stash them first, so there is one place the work lives."
}

# Clone rather than worktree. A worktree keeps its git dir inside the real
# repository, so confining writes to the workspace would mean granting write
# access to the real object store -- the one thing worth protecting. A clone
# with --no-hardlinks shares nothing: writes in here cannot reach objects out
# there, and the only way back is the explicit fetch that `land` performs.
make_workspace() {
  local root=$1 branch=$2 ws=$3
  mkdir -p "$(dirname "$ws")"
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git clone --quiet --no-hardlinks --branch "$branch" "$root" "$ws" \
      || die "could not clone $branch into $ws"
  else
    git clone --quiet --no-hardlinks "$root" "$ws" \
      || die "could not clone $root into $ws"
    git -C "$ws" checkout --quiet -b "$branch" \
      || die "could not create branch $branch in the workspace"
  fi
}

cmd_start() {
  local branch="" root ws slot settings
  while [[ ${1:-} == -* ]]; do
    case $1 in
      -b | --branch)
        [[ -n ${2:-} ]] || die "--branch needs a value"
        branch=$2
        shift 2
        ;;
      -h | --help) usage ;;
      *) die "unknown option: $1" ;;
    esac
  done

  root=$(git rev-parse --show-toplevel 2> /dev/null) || die "not inside a git repository"
  root=$(resolve "$root")
  require_clean_tree "$root" "the repository"
  [[ -n $branch ]] || branch=$(git -C "$root" symbolic-ref --quiet --short HEAD) \
    || die "detached HEAD -- pass --branch"

  slot=$(slot_for "$root" "$branch")
  ws=$slot/repo
  settings=$slot/sandbox.json
  if [[ -e $ws ]]; then
    printf 'reusing the existing workspace for %s\n' "$branch" >&2
  else
    make_workspace "$root" "$branch" "$ws"
  fi
  ws=$(resolve "$ws")

  sandbox_supported || die "no OS sandbox available here, so the work cannot be confined. Refusing to pretend otherwise."
  workspace_is_denied "$ws" \
    && die "the workspace at $ws sits inside a tree this policy denies editing, so the session could not edit its own files. Point LASTLIGHT_WORK_ROOT somewhere else."
  work_settings_json "$ws" "$root" > "$settings"

  if [[ ${LASTLIGHT_WORK_VERIFY:-on} == off ]]; then
    printf 'containment NOT verified (LASTLIGHT_WORK_VERIFY=off)\n' >&2
  elif work_verify "$settings" "$ws" "$root"; then
    printf 'containment verified: spawned processes and file edits are both confined\n' >&2
  else
    die "the policy did not hold, or the probe could not run. Refusing to open a session that only looks sandboxed. Re-run with LASTLIGHT_WORK_VERIFY=off to accept that risk deliberately."
  fi

  printf 'workspace: %s\n' "$ws" >&2
  printf 'land it with: lastlight-work-sandbox.sh land -b %s\n\n' "$branch" >&2
  cd "$ws"
  exec claude --settings "$settings" "$@"
}

# Bring the work back. Fast-forward only, and deliberately no --force anywhere:
# a diverged branch means the two histories disagree, which is a thing for a
# person to look at, not for a script to resolve by overwriting one of them.
#
# This does NOT check for a review marker, and that is not an oversight. A
# marker proving a review is only worth anything if the reviewed code could not
# have written it, and everything inside the workspace is under the session's
# control -- including its own git dir. So the proof lives where the session
# cannot reach: markers are written only by a review run in the real
# repository, and only a marker opens the push gate. Landing moves code onto a
# branch; it does not make that code pushable.
cmd_land() {
  local branch="" root ws slot before after
  while [[ ${1:-} == -* ]]; do
    case $1 in
      -b | --branch)
        [[ -n ${2:-} ]] || die "--branch needs a value"
        branch=$2
        shift 2
        ;;
      -h | --help) usage ;;
      *) die "unknown option: $1" ;;
    esac
  done

  root=$(git rev-parse --show-toplevel 2> /dev/null) || die "not inside a git repository"
  root=$(resolve "$root")
  [[ -n $branch ]] || branch=$(git -C "$root" symbolic-ref --quiet --short HEAD) \
    || die "detached HEAD -- pass --branch"

  slot=$(slot_for "$root" "$branch")
  ws=$slot/repo
  [[ -d $ws ]] || die "no workspace for $branch -- start one with: lastlight-work-sandbox.sh start -b $branch"
  require_clean_tree "$ws" "the workspace"
  # Confirm the workspace is a clone of THIS repository before fetching from
  # it. Slots were once keyed by basename alone, so a workspace belonging to a
  # different project could occupy this path -- and landing it created a branch
  # here holding that project's entire history. Unique keys make the collision
  # impossible; this makes a wrong workspace impossible to land, whatever put
  # it there.
  local ws_origin
  ws_origin=$(git -C "$ws" remote get-url origin 2> /dev/null || true)
  [[ -n $ws_origin && $(resolve "$ws_origin") == "$root" ]] \
    || die "the workspace at $ws is not a clone of this repository (its origin is '${ws_origin:-unset}'). Refusing to fetch from it."
  git -C "$ws" show-ref --verify --quiet "refs/heads/$branch" \
    || die "the workspace has no branch $branch"

  before=$(git -C "$root" rev-parse --verify --quiet "refs/heads/$branch" || true)
  # git refuses to fetch INTO a branch that is checked out, and that is the
  # normal case here rather than an odd one: `start` defaults to the branch the
  # repository is already on and never moves it, so landing back onto that same
  # branch hit the refusal every time. Worse, the failure was reported as
  # history divergence, sending the reader to reconcile a conflict that did not
  # exist. The suite missed it because its own case switched away first.
  #
  # When it IS the checked-out branch, fast-forward the working tree instead --
  # still ff-only, and still refusing a dirty tree, so nothing is overwritten.
  if [[ $(git -C "$root" symbolic-ref --quiet --short HEAD || true) == "$branch" ]]; then
    require_clean_tree "$root" "the repository"
    git -C "$root" pull --quiet --ff-only "$ws" "refs/heads/$branch" \
      || die "refusing to land: $branch in the repository is not an ancestor of the workspace's. The two have diverged -- reconcile them by hand."
  else
    git -C "$root" fetch --quiet "$ws" "refs/heads/$branch:refs/heads/$branch" \
      || die "refusing to land: $branch in the repository is not an ancestor of the workspace's. The two have diverged -- reconcile them by hand."
  fi
  after=$(git -C "$root" rev-parse "refs/heads/$branch")

  if [[ $before == "$after" ]]; then
    printf 'nothing to land: %s is already at %s\n' "$branch" "${after:0:12}" >&2
    return 0
  fi
  printf 'landed %s: %s -> %s\n' "$branch" "${before:0:12}${before:+ }" "${after:0:12}" >&2
  printf 'it is NOT pushable yet -- review it here, in the real repository:\n' >&2
  printf '  git switch %s && %s/lastlight-review-run.sh\n' "$branch" "$SELF_DIR" >&2
}

cmd_list() {
  local root repo_root slot branch ws state
  root=$(git rev-parse --show-toplevel 2> /dev/null) || die "not inside a git repository"
  repo_root="$WORK_ROOT/$(repo_key "$(resolve "$root")")"
  [[ -d $repo_root ]] || {
    printf 'no workspaces for this repository\n' >&2
    return 0
  }
  while IFS= read -r slot; do
    ws=$slot/repo
    branch=${slot#"$repo_root"/}
    state=clean
    [[ -n $(git -C "$ws" status --porcelain 2> /dev/null) ]] && state=dirty
    printf '%-40s %-6s %s\n' "$branch" "$state" "$(git -C "$ws" rev-parse --short HEAD 2> /dev/null || echo '-')"
  done < <(find "$repo_root" -type d -name repo -exec dirname {} \; | sort)
}

main() {
  case ${1:-} in
    start)
      shift
      cmd_start "$@"
      ;;
    land)
      shift
      cmd_land "$@"
      ;;
    list)
      shift
      cmd_list "$@"
      ;;
    -h | --help | "") usage ;;
    *) die "unknown command: $1 (expected start, land or list)" ;;
  esac
}

# Sourcing must not run anything: the test suite loads this file to exercise
# the policy and verdict functions directly, which is the only way to test them
# without spending a model call on every assertion.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
