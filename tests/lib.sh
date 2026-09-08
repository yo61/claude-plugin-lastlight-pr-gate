#!/usr/bin/env bash
# Helpers shared by the suites, for the things that differ between this machine
# and a CI runner.
#
# Both bugs this file exists for reached CI green-locally, red-there — and one
# of them was worse than a failure: a missing tool made an assertion pass for
# the wrong reason.

# An inode's link count. 1 means the file is not shared with another tree.
#
# `stat -f %l || stat -c %h` looks like a portable fallback and is not. On GNU,
# `-f` is not an unknown flag that errors and falls through — it means
# "filesystem status", succeeds, and prints a block of unrelated information
# that the `||` never sees. The runner then compared that block against `1`.
#
# Only GNU stat has --version, so ask it which one this is.
link_count() {
  if stat --version > /dev/null 2>&1; then
    stat -c %h "$1"
  else
    stat -f %l "$1"
  fi
}

# Count matching lines in a file, or 0 if the file is absent.
#
# `grep`, not `rg`: ripgrep is installed on this machine and not on a stock
# runner. Wrapped in `|| echo 0`, its absence does not look like a missing tool
# — it looks like the answer, which turned one assertion red and made another
# pass for a reason that had nothing to do with what it claimed to test.
count_matching() {
  local pattern=$1 file=$2 n
  # `grep -c` prints 0 AND exits non-zero when nothing matches, so a trailing
  # `|| echo 0` appends a second line and the caller compares "0\n0" against
  # "0". Capture first, then default only if the capture produced nothing.
  n=$(grep -c "$pattern" "$file" 2> /dev/null) || true
  [[ -n $n ]] || n=0
  printf '%s' "$n"
}

# Clear configuration the tests must not inherit.
#
# Claude Code's own sandbox exports GIT_CONFIG_COUNT=2 with safe.directory
# keys. A bare COUNT with no matching KEY makes git fail outright, so a suite
# run from a sandboxed session does not report a few odd results -- the gate
# suite went from 160 passing to 103 FAILING, and the work-sandbox suite could
# not clone at all. The prek hooks and readme-counts run in that environment
# when a commit is made from such a session, so the commit fails for a reason
# that has nothing to do with the commit.
#
# One suite also ASSERTS on these variables, to prove the runner sets them on
# the reviewer's command rather than exporting them. Inheriting them made that
# assertion read the invoking shell instead of the code under test -- it failed
# while the thing it describes was working.
#
# Only the application's own configuration goes: PATH, HOME, TMPDIR and the
# locale are what any process needs. A test that wants one of these sets it.
clear_inherited_config() {
  local var
  while IFS= read -r var; do
    [[ -n $var ]] && unset "$var"
  done < <(env | awk -F= '/^GIT_CONFIG_[A-Za-z0-9_]*=/ { print $1 }')
}
