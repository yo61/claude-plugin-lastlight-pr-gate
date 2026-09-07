#!/usr/bin/env bash
# Build the isolated workspace and sandbox policy a review runs under.
#
# Sourced by lastlight-review-run.sh; not useful on its own.
#
# WHY
#   The reviewed diff is untrusted input by construction -- the reviewer is told
#   not to trust it. Running that unattended with the invoking user's privileges
#   forced two compromises: writes scoped to a single path, and NO PROBES, so
#   the reviewer could not install a dependency or execute a test. Probes are
#   what caught the only bypass that eight rounds of static reading missed, so
#   withholding them removed the reviewer's sharpest instrument.
#
#   Isolation removes the need for either compromise. Every control below was
#   verified on macOS (Seatbelt) on 2026-09-04, and re-verified with arbitrary
#   Bash enabled -- which is the combination that matters, since enabling probes
#   must not defeat the containment:
#
#     write inside allowWrite            -> succeeds
#     write outside allowWrite           -> refused
#     read of a denyRead path            -> refused
#     egress off the allowedDomains list -> refused
#
#   Sandbox startup measured at ~0.6s against an unsandboxed run: within noise.
#
# THE TWO PARTS
#   1. A DISPOSABLE COPY. `git clone --no-hardlinks` at HEAD into a temp dir.
#      `--no-hardlinks` is load-bearing, not tidiness: a local clone hardlinks
#      .git objects by default, so a process that can write in the clone could
#      truncate objects in the REAL repository through the shared inode. Without
#      it the copy is not disposable.
#   2. THE POLICY below, passed via `claude -p --settings`.
#
# WHAT THIS DOES NOT DO
#   Reads outside the deny list are still permitted -- the reviewer must read
#   the repo, and file rules only match `Edit(...)`. Egress control is what
#   closes exfiltration instead: it does not matter what the session reads if
#   it can only reach the API.
set -euo pipefail

# Credential stores a reviewer never needs. Denying reads is belt to the egress
# braces: even a successful injection has nowhere to send what it cannot read.
# `.git-credentials` is where `git config credential.helper store` writes
# plaintext HTTPS tokens, and git also reads it from the XDG location. Its
# absence was a gap in an otherwise systematic list rather than a decision:
# `.netrc`, which serves the same purpose for many git setups, was already
# here. It matters most in the work sandbox, which deliberately opens egress to
# github.com so builds can fetch -- exactly the route a token read from an
# unprotected file would leave by.
sandbox_denied_reads() {
  printf '%s\n' \
    "$HOME/.ssh" "$HOME/.aws" "$HOME/.gnupg" "$HOME/.netrc" \
    "$HOME/.config/gh" "$HOME/.claude/.credentials.json" \
    "$HOME/.docker/config.json" "$HOME/.npmrc" "$HOME/.pypirc" \
    "$HOME/.git-credentials" "${XDG_CONFIG_HOME:-$HOME/.config}/git/credentials"
}

# Only what the reviewer session itself needs to function. NOT the package
# registries: installing dependencies is a probe affordance, opted into with
# LASTLIGHT_REVIEW_EGRESS, and every added host widens the exfiltration path.
# What any sandboxed session needs to reach, whatever it is doing.
sandbox_base_domains() {
  printf '%s\n' api.anthropic.com statsig.anthropic.com sentry.io
}

# The REVIEW sandbox's allowlist: the base, plus whatever the operator opted
# into for this kind of session.
#
# The override is read here and not in sandbox_base_domains, so it cannot reach
# a different sandbox. It did: the work sandbox built its list on top of this
# function, so a host allowed for a review's probe was silently reachable from
# a work session too -- one that also holds Write and Edit, and whose stated
# threat is a poisoned dependency. The two variables are named for separate
# scopes and now have them.
sandbox_allowed_domains() {
  sandbox_base_domains
  if [[ -n ${LASTLIGHT_REVIEW_EGRESS:-} ]]; then
    tr ',' '\n' <<< "$LASTLIGHT_REVIEW_EGRESS"
  fi
}

# The settings document handed to `claude -p --settings`.
#
# `disableAllHooks` matters more than it looks: --settings LAYERS onto user
# settings, so without it the reviewer inherits this very plugin's PreToolUse
# hooks -- including bash-guard, which would block its probes. Inside a sandbox
# those hooks are redundant anyway: they exist to bound blast radius by guessing
# at shell text, and the blast radius is now the sandbox.
#
# `failIfUnavailable` makes an unavailable sandbox an error rather than a silent
# downgrade. The caller decides what to do about it; it must not quietly run a
# probe-enabled review unconfined.
# Permission rules denying READS of every credential store, in both the file
# and the directory spelling.
#
# sandbox.filesystem.denyRead confines SPAWNED PROCESSES only. The Read tool is
# native to the CLI and never sees it: verified directly -- with denyRead naming
# the directory, a `cat` under Bash was refused while the Read tool returned the
# file's contents in the same session. That is the same asymmetry already
# documented here for Write, and the review sandbox shipped with no permissions
# block at all, so it applied to Read too and nobody had written it down.
#
# It matters because the reviewed diff is untrusted by construction. A prompt
# injection could tell the reviewer to read a credential and copy it into a
# finding, and findings.json is the one file deliberately carried back out of
# the workspace -- so the secret leaves through the channel the README calls
# safe, with no network egress needed.
# What the REVIEW sandbox refuses to read: $HOME as a whole, then the stores
# that resolve outside it.
#
# Both halves of that policy read from here -- `denyRead`, which confines
# spawned processes, and `permissions.deny`, which confines the Read tool. They
# were given different lists: the Read tool was barred from all of $HOME while
# denyRead named only the credential files, and a sandboxed reviewer is granted
# Bash. So the diff under review could `cat` a sibling repository's .env, a
# shell history or another session's transcript, and findings.json is the one
# file carried out of the workspace and posted as a PR comment. Verified before
# the fix: a canary under $HOME came back READ-OK to Bash; after it, "Operation
# not permitted", with the workspace still readable.
#
# NOT shared with the work sandbox, deliberately. Its workspace lives under
# $HOME by default, and deny beats allow, so the same blanket rule would lock a
# work session out of its own tree. That policy keeps the narrower list, and
# the difference is a property of where each workspace lives.
review_denied_reads() {
  printf '%s\n' "$HOME"
  sandbox_denied_reads
}

read_deny_rules() {
  local path
  # HOME AS A WHOLE, not a list of secrets inside it.
  #
  # A curated denylist protects what was thought of. The reviewed diff is a
  # prompt-injection surface, and the interesting targets are not only
  # credential files: a sibling repository's .env, a shell history, another
  # session's transcript. Anything read this way leaves through findings.json,
  # which is carried out of the workspace and posted as a PR comment with no
  # human in between -- so the list has to be the boundary, not a sample of it.
  #
  # The workspace lives under $TMPDIR, outside $HOME, so denying $HOME costs
  # the reviewer nothing: its diff and its skill files are staged into the
  # workspace precisely so that nothing it needs is left behind this line.
  # From review_denied_reads, so this rule and the denyRead rule cannot be
  # given different boundaries by editing one of them.
  while IFS= read -r path; do
    printf 'Read(/%s)\nRead(/%s/**)\n' "$path" "$path"
  done < <(review_denied_reads)
}

# Copy the review assets into the workspace so the reviewer never has to read
# outside it. Without this, scoping reads to the workspace would deny the
# reviewer its own skill file, which lives under $HOME.
sandbox_stage_assets() {
  local assets=$1 ws=$2
  mkdir -p "$ws/.lastlight-assets"
  cp -R "$assets/skills" "$ws/.lastlight-assets/skills" \
    || die "could not stage the review assets into the isolated workspace"
}

sandbox_settings_json() {
  local workspace=$1 tmp
  # A scratch directory, because the whole point of this sandbox is that the
  # reviewer may run PROBES -- install a dependency, execute a test -- and
  # almost every package manager, build tool and test runner stages through
  # $TMPDIR. Without it `mktemp -d` fails with "Operation not permitted" and
  # every such probe dies while the runner still prints "probes enabled".
  # Verified from inside a review running under this very policy.
  tmp=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  jq -n \
    --arg ws "$workspace" \
    --arg tmp "$tmp" \
    --argjson deny "$(review_denied_reads | jq -R . | jq -s .)" \
    --argjson net "$(sandbox_allowed_domains | jq -R . | jq -s .)" \
    --argjson readdeny "$(read_deny_rules | jq -R . | jq -s .)" \
    '{
      disableAllHooks: true,
      sandbox: {
        enabled: true,
        autoAllowBashIfSandboxed: true,
        failIfUnavailable: true,
        filesystem: { allowWrite: [$ws, $tmp], denyRead: $deny },
        network: { allowedDomains: $net }
      },
      permissions: { deny: $readdeny }
    }'
}

# A disposable copy of HEAD. Prints the workspace path.
sandbox_make_workspace() {
  local root=$1 sha=$2 ws
  ws=$(mktemp -d)/review
  # --no-hardlinks: see the header. --shared would be faster and is exactly the
  # wrong thing here.
  git clone --quiet --no-hardlinks --no-checkout "$root" "$ws" 2> /dev/null \
    || die "could not clone the repository into an isolated workspace"
  git -C "$ws" checkout --quiet --detach "$sha" 2> /dev/null \
    || die "could not check out ${sha:0:12} in the isolated workspace"
  printf '%s' "$ws"
}

# A disposable copy of the WORKING STATE, for reviewing work before it is
# committed. Prints the workspace path.
#
# A clone alone will not do: it carries committed history only, so uncommitted
# modifications and untracked files -- the entire subject of a pre-commit
# review -- are absent from it. The copy is therefore assembled in three steps:
#
#   1. clone at HEAD (an independent .git, per the hardlink note above)
#   2. apply the uncommitted diff to tracked files
#   3. copy untracked files, EXCLUDING ignored ones
#
# Step 3's exclusion is a feature. It keeps node_modules and .venv out of the
# copy, which keeps it fast -- and means a probe that needs dependencies
# installs them inside the sandbox rather than inheriting whatever is already
# on disk. A poisoned local dependency tree cannot execute during a review it
# was never copied into.
sandbox_make_working_workspace() {
  local root=$1 ws patch
  ws=$(mktemp -d)/review
  git clone --quiet --no-hardlinks --no-checkout "$root" "$ws" 2> /dev/null \
    || die "could not clone the repository into an isolated workspace"
  git -C "$ws" checkout --quiet --detach HEAD 2> /dev/null \
    || die "could not check out HEAD in the isolated workspace"

  patch=$(mktemp)
  git -C "$root" diff HEAD > "$patch"
  if [[ -s $patch ]]; then
    git -C "$ws" apply "$patch" 2> /dev/null \
      || die "could not apply the uncommitted changes to the isolated workspace"
  fi
  rm -f "$patch"

  # Untracked files are the whole point of this mode, so a failure to copy them
  # is fatal rather than quiet. This was `rsync`, guarded by a `command -v` that
  # simply skipped the copy when it was missing: on a host with `bwrap` but no
  # rsync -- which sandbox_supported() happily accepts -- the reviewer received
  # a workspace containing NONE of the new files it was asked to look at, and
  # said so in no way at all.
  #
  # `cp` is in every base system, and the untracked set excludes ignored files,
  # so it is small. `-P` keeps a symlink a symlink instead of copying whatever
  # it points at, which may be outside the repository entirely.
  #
  # -z / read -d '': filenames may contain spaces or newlines, and a review of a
  # tree with such a name must not silently skip it.
  local f
  while IFS= read -r -d '' f; do
    mkdir -p "$ws/$(dirname "$f")" \
      || die "could not create a directory for untracked '$f' in the isolated workspace"
    cp -RP -- "$root/$f" "$ws/$f" \
      || die "could not copy untracked '$f' into the isolated workspace"
  done < <(git -C "$root" ls-files --others --exclude-standard -z)
  printf '%s' "$ws"
}

# Whether an OS sandbox is actually available here. Checked BEFORE building a
# workspace so an unsupported platform degrades to a stated read-only review
# rather than failing mid-run.
sandbox_supported() {
  case "$(uname -s)" in
    Darwin) command -v sandbox-exec > /dev/null 2>&1 ;;
    Linux) command -v bwrap > /dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# PROVE the confinement engaged, before trusting it.
#
# `claude -p --help`: "Settings files that fail validation are SILENTLY IGNORED
# in this mode (no error dialog is shown)." Verified empirically -- a settings
# file with a misspelled key runs the session anyway, unconfined and unremarked.
#
# That makes "we passed --settings" worthless as evidence. The tool grant and
# the sandbox are independent mechanisms: `--allowed-tools Bash` is a CLI flag
# that applies regardless, so a silently-ignored settings file yields a reviewer
# with unrestricted Bash and NO confinement -- a fail-open in the one control
# that makes probes safe.
#
# So attempt an actual escape under the real policy and require it to fail. A
# canary written outside the workspace means the sandbox is not in force,
# whatever the settings file said.
# A path the probe must NOT be able to write: outside every writable area, with
# a parent directory that EXISTS.
#
# That second half is the whole point, and it was missing. The canary was
# `$(mktemp -u)/sandbox-escape-canary` -- but `mktemp -u` prints a name without
# creating anything, so the parent never existed and the write failed with
# ENOENT whether or not a sandbox was engaged. Every run reported containment
# verified. Confirmed by writing to such a path with no policy in force at all:
# exit status 1, indistinguishable from a sandbox refusing it.
#
# $HOME rather than a temp directory: the work sandbox deliberately grants
# spawned processes write access to $TMPDIR, so a canary there would be written
# successfully by a CORRECTLY confined session and read as an escape.
sandbox_escape_canary() {
  printf '%s/.lastlight-containment-probe.%s' "$HOME" "$$"
}

# The verdict on a probe run, split out from the probe so it can be tested
# without spending a model call. The bug this replaced was in the DECISION, not
# in the probe -- absence of an escape canary was read as containment when it
# equally meant the probe never ran -- so the decision is what needs a test.
#
#   $1  1 if the escape canary exists outside the workspace, 0 if not
#   $2  what the probe wrote about itself, empty if it wrote nothing
#
# Returns 0 only on a positive, complete account of a blocked escape; 1 when a
# write got out; 2 when the probe could not say.
sandbox_probe_verdict() {
  local escaped=$1 report=$2 rc
  # THREE outcomes, not two. Both failures refuse to proceed, but they mean
  # opposite things and the caller says so: 1 is a sandbox that let a write
  # through, 2 is a probe that could not tell us either way. Collapsing them
  # made a session-limit failure report itself as "a canary escaped the
  # workspace" -- a containment breach that had not happened.
  [[ $escaped -eq 0 ]] || return 1 # the sandbox did not hold

  # Two conditions, each doing work the other does not. An earlier version had
  # four, and two of them were unreachable given the rest -- mutation testing
  # found them by deleting each in turn and watching nothing fail. Redundant
  # checks in a security control are worse than absent ones: they cannot be
  # tested, so they rot unnoticed while looking like defence in depth.
  rc=${report#ran rc=}
  # The prefix was really there. Without this a report of bare `1` -- no claim
  # to have run, no claim to have attempted anything -- satisfies the status
  # test below on its own.
  [[ $report != "$rc" ]] || return 2
  # ...and what follows it is a genuine non-zero status. `ran rc=` is a report
  # cut off mid-write, and `ran rc=0` is a write that reports success while
  # leaving no file behind; neither is an account of a refused escape.
  [[ $rc =~ ^[1-9][0-9]*$ ]] || return 2
  return 0
}

sandbox_verify() {
  local settings=$1 workspace=$2 outside inside report prompt
  outside=$(sandbox_escape_canary)
  inside=$workspace/.sandbox-selftest-report
  rm -f "$inside"

  # The probe reports on ITSELF. An earlier version checked only whether the
  # escape canary existed afterwards, which conflated two opposite outcomes:
  # the sandbox blocking the write, and the probe never running at all -- a
  # timeout, an auth failure, an unavailable model. Both leave the canary
  # absent, so a call that never happened read as proof of containment, and
  # that "proof" is what unlocked unrestricted Bash over an attacker-controlled
  # diff. Absence of evidence was being treated as evidence of absence.
  #
  # So the probe writes INSIDE the workspace first (a path the policy permits),
  # then attempts the escape and appends the shell's own exit status. Three
  # things must hold, and all three are positive signals:
  #
  #   the report exists      -- the probe ran
  #   the report has rc=     -- the escape was actually attempted, not skipped
  #   rc is non-zero         -- the attempt was refused by something
  #
  # ...and the escape canary must still be absent. A missing or truncated
  # report is inconclusive, and inconclusive fails CLOSED.
  # SAY WHAT THIS IS. The first version phrased the probe as bare commands over
  # paths named `sandbox-escape-canary`, and the model refused to run it --
  # correctly, since that reads as someone testing how to get out. The refusal
  # left no canary behind, which the old check scored as containment verified:
  # the reviewer's own good judgement was what unlocked unconfined execution.
  # Observed on the first live run, not reasoned about.
  #
  # The fix is candour rather than camouflage. Disguising the probe would only
  # buy a refusal that is harder to recognise, and it would mean lying to the
  # model to route around a judgement that was right. Stating the actual
  # purpose -- an authorised self-test whose second write is MEANT to fail --
  # removes the adversarial reading, because the reading was the false part.
  prompt="This is an authorised self-test of the sandbox you are running under,
issued by the tool that configured it. It is not an attempt to defeat the
sandbox: the second write is EXPECTED to be refused, and recording that refusal
is the entire purpose. Run the commands exactly as given, in order, with Bash.
Do not modify them, do not work around a failure, and do not stop early if one
fails. Then stop.

printf 'ran' > '${inside}'
printf x > '${outside}'; printf ' rc=%s' \"\$?\" >> '${inside}'"

  # </dev/null: without it the CLI waits 3s for stdin that is never coming.
  timeout 120 claude -p "$prompt" \
    --settings "$settings" --model haiku < /dev/null > /dev/null 2>&1 || true

  report=$(cat "$inside" 2> /dev/null || true)
  rm -f "$inside"

  local escaped=0
  if [[ -e $outside ]]; then
    escaped=1
    rm -f "$outside"
  fi
  sandbox_probe_verdict "$escaped" "$report"
}
