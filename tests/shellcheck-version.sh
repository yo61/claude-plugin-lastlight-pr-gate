#!/usr/bin/env bash
# Fail if the local shellcheck is not the one CI will use.
#
# CI installs the pinned version; this checks the local one matches, so "clean
# locally" means the same thing in both places. Without it the two ran
# different builds, which report the same construct under different codes: an
# uncalled function is SC2329 on 0.11 and SC2317 per body line on older ones.
# A disable written against the local answer passed here and failed there.
#
# On a mismatch this fails rather than warns. A lint that reports something
# different from the lint that gates the merge is not a lint.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SELF_DIR
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../.shellcheck-version
source "$SELF_DIR/../.shellcheck-version"

if ! command -v shellcheck > /dev/null 2>&1; then
  printf 'shellcheck is not installed. This project pins %s; install that version.\n' \
    "$SHELLCHECK_VERSION" >&2
  exit 1
fi

# `shellcheck --version` prints a block; the version is its own field.
have=$(shellcheck --version | sed -n 's/^version: //p')

if [[ $have != "$SHELLCHECK_VERSION" ]]; then
  printf 'shellcheck %s is installed, but this project pins %s -- the version CI runs.\n' \
    "${have:-unknown}" "$SHELLCHECK_VERSION" >&2
  printf 'Different builds raise different codes for the same code, so a clean run here\n' >&2
  printf 'would not mean a clean run in CI. Install %s, or bump .shellcheck-version\n' \
    "$SHELLCHECK_VERSION" >&2
  printf '(and its sha256) deliberately and re-check the disables.\n' >&2
  exit 1
fi

# ...and both invocations have to NAME the config, or shellcheck searches from
# each file upward and then $HOME -- which is how a personal ~/.shellcheckrc
# decided what ran locally while CI saw something else. Same version, same
# command, different settings.
for caller in .github/workflows/ci.yaml .pre-commit-config.yaml; do
  if ! grep -q -- '--rcfile=.shellcheckrc' "$SELF_DIR/../$caller"; then
    printf '%s invokes shellcheck without --rcfile, so it reads whatever config\n' "$caller" >&2
    printf 'the machine happens to provide. Name the file.\n' >&2
    exit 1
  fi
done

printf 'shellcheck %s matches the pinned version, and both callers name the config\n' "$have"
