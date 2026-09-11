#!/usr/bin/env bash
# The README's test-count table must match what the suites actually print.
#
# It went stale twice in one day: written, then left behind by the next round
# of cases. Each time a reviewer had to notice. The paragraph under that table
# promises the numbers are "what each suite prints when you run it", which
# makes a stale row a broken promise rather than a typo -- a reader who trusts
# the framing and checks gets a wrong answer.
#
# So the promise is enforced instead of restated. This is not a test suite and
# reports no count of its own: it would otherwise have to appear in the table
# it checks, and a self-referential row is exactly the kind of thing that goes
# quietly wrong.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
found=0

# shellcheck disable=SC2016  # the backticks in the sed script below are
# markdown table syntax being matched, not a substitution being written.
while read -r suite want; do
  [[ -n $suite ]] || continue
  found=1
  if [[ ! -f tests/$suite ]]; then
    printf 'README names tests/%s, which does not exist\n' "$suite" >&2
    fail=1
    continue
  fi
  # Run it SEPARATELY from reading its output. Piping the suite straight into
  # sed put its exit status under `set -e` and pipefail, so the first genuinely
  # failing suite aborted this script right here -- before any check ran and
  # before anything was printed. A script written because a stale number failed
  # quietly then failed quietly itself, with zero bytes of output, in exactly
  # the case it exists to explain.
  suite_rc=0
  suite_out=$(bash "tests/$suite" 2>&1) || suite_rc=$?
  got=$(printf '%s\n' "$suite_out" | sed -n 's/^passed \([0-9][0-9]*\).*/\1/p' | tail -1)

  if [[ $suite_rc -ne 0 ]]; then
    printf 'tests/%s failed (exit %s), so its count proves nothing:\n%s\n' \
      "$suite" "$suite_rc" "$suite_out" >&2
    fail=1
  elif [[ -z $got ]]; then
    printf 'tests/%s printed no total to compare against\n' "$suite" >&2
    fail=1
  elif [[ $got != "$want" ]]; then
    printf 'README says %s for tests/%s, but it prints %s\n' "$want" "$suite" "$got" >&2
    fail=1
  fi
done < <(sed -n 's/^| `\(lastlight-[a-z-]*\.test\.sh\)` | \([0-9][0-9]*\) |.*/\1 \2/p' README.md)

# A table this cannot find is a table it cannot police, and silence would read
# as agreement.
if [[ $found -eq 0 ]]; then
  printf 'no test-count rows found in README.md -- has the table moved?\n' >&2
  exit 1
fi

[[ $fail -eq 0 ]] || exit 1
echo "README test counts match the suites"
