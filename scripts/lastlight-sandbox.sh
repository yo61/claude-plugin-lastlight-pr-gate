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
# The tool's own workspace, which is never part of the change under review.
#
# Defined here because every script that touches the working tree needs it and
# they kept getting it one at a time: the diff builder excluded it and the
# workspace builder beside it did not, so a previous run's reviewer.log and
# dismissed.json were copied into the tree the next reviewer explores -- an
# "independent" pass reading the last one's transcript and reasoning, which is
# the very thing the `rm -f` at the start of a run exists to prevent.
#
# Invisible on a machine whose global gitignore covers `.lastlight/`, which is
# why it survived: `--exclude-standard` reads that file, so the leak does not
# happen for the author and does happen for everyone else.
readonly LASTLIGHT_EXCLUDE=':(exclude).lastlight/'

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
# The name of the timeout command this machine actually has, or nothing.
#
# Both spellings exist in the wild -- macOS ships neither, and GNU coreutils is
# packaged unprefixed on Linux and sometimes only g-prefixed elsewhere. The
# dependency check used to accept either and every call site then ran the
# literal `timeout`, through `env`, which resolves from PATH: so on a machine
# with only the g-prefixed build the check passed and every call failed with
# 127. The probe swallows that with `|| true`, so the run died blaming the
# model for being unavailable.
#
# Resolved once and used everywhere, so the thing checked for is the thing run.
sandbox_timeout_cmd() {
  if command -v timeout > /dev/null 2>&1; then
    printf 'timeout'
  elif command -v gtimeout > /dev/null 2>&1; then
    printf 'gtimeout'
  fi
}

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

# Paths inside the workspace that belong to the RUNNER, not to the branch.
#
# Each is written by this process, outside the sandbox, with the user's
# privileges -- so a file the branch committed at one of these names is not
# data, it is a redirect for a privileged write.
sandbox_runner_paths() {
  printf '%s\n' .lastlight-sandbox.json .lastlight .lastlight-assets
}

# Move anything the branch committed at those names out of the way.
#
# `mv`, not `rm -rf`: the whole workspace goes at the EXIT trap anyway, so
# deleting buys nothing, and leaving the files where the reviewer can see them
# is right -- a branch that commits a symlink where the review tooling writes
# is a finding in itself. The suffix carries $$ so the branch cannot have
# committed the quarantine name either.
sandbox_clear_runner_paths() {
  local ws=$1 rel target
  [[ -n $ws && -d $ws ]] || die "cannot clear runner paths: '$ws' is not a directory"
  while IFS= read -r rel; do
    # -e is false for a dangling symlink, which is exactly the case that
    # matters, so -L has to be asked separately.
    [[ -e "$ws/$rel" || -L "$ws/$rel" ]] || continue
    target="$ws/$rel.branch-committed.$$"
    mv "$ws/$rel" "$target" \
      || die "could not move the branch's own $rel out of the way in $ws"
    printf '  moved committed %s aside: it names a path the runner writes\n' "$rel" >&2
  done < <(sandbox_runner_paths)
}

# What the reviewer's environment is allowed to contain.
#
# Configuration, not credentials: enough to find a binary, resolve a host,
# trust a CA and write a temp file. Everything else is dropped, which is what
# takes GITHUB_TOKEN, GH_TOKEN, NPM_TOKEN and the AWS variables out of reach.
#
# A keep-list rather than a denylist of token names, for the reason
# read_deny_rules already gives about reads: a curated denylist protects what
# was thought of, and a reviewer that can read one variable can read them all.
sandbox_env_keep() {
  printf '%s\n' \
    PATH HOME SHELL USER LOGNAME \
    TMPDIR TMP TEMP \
    TERM LANG LC_ALL \
    HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy \
    SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS \
    XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
}

# The environment to hand a sandboxed `claude`, as NAME=value lines.
#
# WHAT THIS DOES NOT DO, stated plainly: ANTHROPIC_* and CLAUDE_* are passed
# through, and ANTHROPIC_API_KEY is a credential. The session cannot
# authenticate without it, so scrubbing it would not harden the review, it
# would end it -- and the reviewer holding the key that pays for the reviewer
# is a different exposure from it holding a key to someone's repositories. The
# sandbox denies READING ~/.claude/.credentials.json, and this is the gap
# beside that rule: closing it means the CLI scrubbing its own children's
# environment, which cannot be done from out here.
sandbox_reviewer_env() {
  local name
  while IFS= read -r name; do
    [[ -n ${!name:-} ]] && printf '%s=%s\n' "$name" "${!name}"
  done < <(sandbox_env_keep)
  # awk rather than sed: this was first written as a BRE alternation,
  # \(A\|B\), which is a GNU extension. BSD sed does not implement it and
  # does not error either -- it matches nothing, so the passthrough silently
  # dropped every variable it exists to carry. Caught only because the suite
  # asserts the exception rather than trusting it.
  while IFS= read -r name; do
    [[ -n $name ]] && printf '%s=%s\n' "$name" "${!name}"
  done < <(env | awk -F= '/^(ANTHROPIC|CLAUDE)_[A-Za-z0-9_]*=/ { print $1 }')
}

# Copy the review assets into the workspace so the reviewer never has to read
# outside it. Without this, scoping reads to the workspace would deny the
# reviewer its own skill file, which lives under $HOME.
sandbox_stage_assets() {
  local assets=$1 ws=$2
  # `cp -R src dst` copies INTO dst when dst already exists as a directory, and
  # exits 0 doing it -- so a committed .lastlight-assets/skills/pr-review/
  # SKILL.md stayed at the path the prompt hands the reviewer while the real
  # skill landed a level deeper, and `|| die` never fired. The reviewed branch
  # would have been supplying the reviewer's instructions.
  #
  # A precondition rather than a defensive `rm`: the caller clears the runner's
  # paths, and if that stops happening this says so instead of quietly running
  # a review the branch wrote the rules for.
  [[ ! -e "$ws/.lastlight-assets" && ! -L "$ws/.lastlight-assets" ]] \
    || die "the workspace already has .lastlight-assets; refusing to stage the review skill on top of it"
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
  # --binary, or a changed binary file yields a "Binary files differ" stanza with
  # no patch data and `git apply` refuses the whole thing -- taking down the
  # working-tree review the README presents as the primary way to review before
  # committing. One changed image anywhere in the repository was enough.
  git -C "$root" diff --binary HEAD -- "$LASTLIGHT_EXCLUDE" > "$patch"
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
  done < <(git -C "$root" ls-files --others --exclude-standard -z -- "$LASTLIGHT_EXCLUDE")
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
# A file under $HOME holding a token the reviewer must never be able to read.
#
# The escape canary tests whether the OS sandbox stops a spawned process
# WRITING out. This one tests the other mechanism entirely: the Read tool is
# native to the CLI, never sees sandbox.filesystem, and is confined only by the
# permissions.deny rules read_deny_rules builds. That mechanism has broken
# silently twice here -- once on the doubled-slash spelling, once when the two
# halves of the policy drifted apart -- and neither break would have moved the
# escape canary.
# The tools the probe is granted, as a function so it can be asserted on. A
# tool the probe does not have is a policy the probe cannot test: without Read
# it reported "refused" even with the Read rules stripped entirely.
sandbox_probe_tools() {
  printf 'Bash Read'
}

sandbox_read_canary() {
  printf '%s/.lastlight-read-probe.%s' "$HOME" "$$"
}

# The token written into it. Distinct per run so a stale file from a killed
# probe cannot be mistaken for this one's evidence.
sandbox_read_token() {
  printf 'lastlight-read-canary-%s' "$$"
}

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
  local escaped=$1 report=$2 token=${3:-} rc
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
  local rest
  rest=${report#ran rc=}
  # The prefix was really there. Without this a report of bare `1` -- no claim
  # to have run, no claim to have attempted anything -- satisfies the status
  # test below on its own.
  [[ $report != "$rest" ]] || return 2
  # The status is its own field, taken up to the first space: the report
  # continues past it with the read result, and matching the whole remainder
  # against a number rejected every report that carried one.
  rc=${rest%% *}
  # ...and what follows the prefix is a genuine non-zero status. `ran rc=` is a
  # report cut off mid-write, and `ran rc=0` is a write that reports success
  # while leaving no file behind; neither is an account of a refused escape.
  [[ $rc =~ ^[1-9][0-9]*$ ]] || return 2

  # The READ half, judged the same way: positive evidence that it was attempted,
  # and the token itself as proof of what happened. Self-reporting alone would
  # not do -- a model that says REFUSED without trying looks identical to one
  # that was refused. The token can only appear here by having been read.
  if [[ -n $token ]]; then
    [[ $report == *" read="* ]] || return 2 # the read was never attempted
    [[ $report != *"$token"* ]] || return 1 # ...and it succeeded: not contained
  fi
  return 0
}

sandbox_verify() {
  local settings=$1 workspace=$2 outside inside report prompt
  outside=$(sandbox_escape_canary)
  inside=$workspace/.sandbox-selftest-report
  rm -f "$inside"

  # The Read-tool half of the proof. Planted before the probe and removed after
  # it, whatever happens.
  local readcanary token
  readcanary=$(sandbox_read_canary)
  token=$(sandbox_read_token)
  printf '%s\n' "$token" > "$readcanary"

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
printf x > '${outside}'; printf ' rc=%s' \"\$?\" >> '${inside}'

Then, with the Read tool and not with Bash, attempt to read the file
'${readcanary}'. That read is ALSO expected to be refused. Whatever happens,
finish by recording the outcome with Bash, appending the file's first line if
you did read it and the word REFUSED if you did not:

printf ' read=%s' '<the first line, or REFUSED>' >> '${inside}'"

  # </dev/null: without it the CLI waits 3s for stdin that is never coming.
  #
  # Read is granted EXPLICITLY. Without it the probe cannot use the tool at all,
  # so it answers "refused" whatever the deny rules say -- verified: with the
  # Read rules stripped entirely the report still read `read=REFUSED`, and the
  # probe declared containment. That is the failure this probe exists to catch,
  # reproduced in the probe itself. Granting the tool is what makes the policy,
  # rather than the tool list, the thing under test.
  # An ARRAY, because `--allowed-tools` takes one argument per tool: a quoted
  # command substitution passes "Bash Read" as a single tool name that matches
  # nothing, and an unquoted one is a word-splitting bug everywhere else.
  local -a probe_tools
  read -r -a probe_tools <<< "$(sandbox_probe_tools)"
  # The same environment the review itself gets, or this would be attesting to
  # a setup the review does not run in.
  local -a probe_env=(-i)
  while IFS= read -r kv; do probe_env+=("$kv"); done < <(sandbox_reviewer_env)
  env "${probe_env[@]}" "$(sandbox_timeout_cmd)" 120 claude -p "$prompt" \
    --settings "$settings" --allowed-tools "${probe_tools[@]}" --model haiku \
    < /dev/null > /dev/null 2>&1 || true

  report=$(cat "$inside" 2> /dev/null || true)
  rm -f "$inside" "$readcanary"

  local escaped=0
  if [[ -e $outside ]]; then
    escaped=1
    rm -f "$outside"
  fi
  sandbox_probe_verdict "$escaped" "$report" "$token"
}
