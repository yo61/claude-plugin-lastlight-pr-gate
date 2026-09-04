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
sandbox_denied_reads() {
  printf '%s\n' \
    "$HOME/.ssh" "$HOME/.aws" "$HOME/.gnupg" "$HOME/.netrc" \
    "$HOME/.config/gh" "$HOME/.claude/.credentials.json" \
    "$HOME/.docker/config.json" "$HOME/.npmrc" "$HOME/.pypirc"
}

# Only what the reviewer session itself needs to function. NOT the package
# registries: installing dependencies is a probe affordance, opted into with
# LASTLIGHT_REVIEW_EGRESS, and every added host widens the exfiltration path.
sandbox_allowed_domains() {
  printf '%s\n' api.anthropic.com statsig.anthropic.com sentry.io
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
sandbox_settings_json() {
  local workspace=$1
  jq -n \
    --arg ws "$workspace" \
    --argjson deny "$(sandbox_denied_reads | jq -R . | jq -s .)" \
    --argjson net "$(sandbox_allowed_domains | jq -R . | jq -s .)" \
    '{
      disableAllHooks: true,
      sandbox: {
        enabled: true,
        autoAllowBashIfSandboxed: true,
        failIfUnavailable: true,
        filesystem: { allowWrite: [$ws], denyRead: $deny },
        network: { allowedDomains: $net }
      }
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
sandbox_verify() {
  local settings=$1 canary
  canary=$(mktemp -u)/sandbox-escape-canary
  timeout 120 claude -p "Use Bash to run: printf x > ${canary} ; then stop." \
    --settings "$settings" --model haiku > /dev/null 2>&1 || true
  if [[ -f $canary ]]; then
    rm -f "$canary"
    return 1
  fi
  return 0
}
