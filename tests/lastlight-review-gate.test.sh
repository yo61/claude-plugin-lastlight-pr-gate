#!/usr/bin/env bash
# Test suite for lastlight-review-gate.sh.
# Run: bash ~/.claude/hooks/lastlight-review-gate.test.sh
#
# The rule under test is unconditional: no unreviewed SHA reaches a remote.
# There is no "does a PR exist?" lookup any more, so every case is decided from
# local state alone and the gate FAILS CLOSED -- there is no `note` verdict.
#
# The repo deliberately has NO remote: the gate must still decide correctly,
# which is what proves it never depended on the network.
set -uo pipefail
# Default to the copy IN THIS REPO, not the one installed under ~/.claude.
# A suite that defaults to the installed copy tests whatever the machine
# happens to have: it passes on a developer box that already has the plugin
# and fails outright on a fresh checkout, which is every CI runner. The three
# newer suites here already resolve from ../scripts; these two did not, so
# `tests/readme-counts.sh` -- which invokes each suite with no environment --
# broke in CI and in the pre-commit hook for anyone without an install.
#
# The override still works, and CI still passes one explicitly.
GATE="${GATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lastlight-review-gate.sh}"
pass=0
fail=0

TMP=$(mktemp -d)
REPO=$TMP/repo
mkdir -p "$REPO"
# `-b main` explicitly: without it the branch name comes from the machine's
# `init.defaultBranch`, which is `main` locally and `master` on a GitHub runner.
# The cases below name `main`, so inheriting `master` made one of them
# unresolvable (fail-closed deny) and another pass for the wrong reason. A test
# declares its environment rather than inheriting it.
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo x > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm "feat: initial"
git -C "$REPO" tag v1
SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" branch other
OUTSIDE=$HOME

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mark() { mkdir -p "$REPO/.git/lastlight-local-review" && echo '{}' > "$REPO/.git/lastlight-local-review/$1.json"; }
unmark() { rm -rf "$REPO/.git/lastlight-local-review"; }

verdict() {
  local out
  out=$(jq -n --arg c "$1" --arg d "$2" \
    '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | "$GATE")
  if [[ -z $out ]]; then
    echo allow
  elif [[ $out == *'"deny"'* ]]; then
    echo deny
  else
    echo note
  fi
}

expect() { # expect <allow|deny> <label> <command> [cwd]
  local want=$1 label=$2 cmd=$3 cwd=${4:-$REPO} got
  got=$(verdict "$cmd" "$cwd")
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL want=%-5s got=%-5s : %s\n' "$want" "$got" "$label"
  fi
}

unmark
echo "--- unreviewed SHA: every push shape is blocked ---"
expect deny "bare git push" 'git push'
expect deny "push -u origin HEAD" 'git push -u origin HEAD'
expect deny "push origin branch" 'git push origin main'
expect deny "push refspec src:dst" 'git push origin HEAD:feature-x'
expect deny "force-with-lease" 'git push --force-with-lease'
expect deny "push --all" 'git push --all origin'
expect deny "push --mirror" 'git push --mirror origin'
expect deny "cd repo && push" "cd $REPO && git push" "$OUTSIDE"
expect deny "pushd repo && push" "pushd $REPO && git push" "$OUTSIDE"
expect deny "subshell (cd && push)" "(cd $REPO && git push)" "$OUTSIDE"
expect deny "git -C repo push" "git -C $REPO push" "$OUTSIDE"
expect deny "push after a commit" 'git commit -m x && git push'

echo "--- nothing new lands: allowed without a review ---"
expect allow "delete a remote branch" 'git push origin --delete old-branch'
expect allow "delete via empty refspec" 'git push origin :old-branch'
expect allow "tags only" 'git push --tags'
expect allow "single tag refspec" 'git push origin refs/tags/v1'
expect allow "dry run" 'git push --dry-run'

echo "--- redirections are not refs ---"
mark "$SHA"
expect allow "push 2>&1 | tail" 'git push 2>&1 | tail -8'
expect allow "push -u origin br 2>&1" 'git push -u origin main 2>&1'
expect allow "push > /dev/null" 'git push > /dev/null'
expect allow "push 2> err.log" 'git push 2> err.log'
expect allow "push >>log 2>&1" 'git push >>log 2>&1'
unmark
expect deny "unreviewed, with redirection" 'git push 2>&1 | tail -8'

echo "--- unresolvable ref: fails CLOSED ---"
expect deny "push a nonexistent branch" 'git push origin no-such-branch-xyz'

echo "--- reviewed SHA: unblocked ---"
mark "$SHA"
expect allow "bare push (marker at HEAD)" 'git push'
expect allow "push -u origin HEAD" 'git push -u origin HEAD'
expect allow "refspec from HEAD" 'git push origin HEAD:feature-x'
expect allow "gh pr create (marker)" 'gh pr create --fill'

echo "--- PR-opening without a marker ---"
unmark
expect deny "gh pr create" 'gh pr create --fill'
expect deny "gh pr ready" 'gh pr ready 42'
expect deny "gh pr reopen" 'gh pr reopen 42'
expect deny "gh api POST /pulls" 'gh api -X POST repos/o/r/pulls -f title=x'

# `gh api` is a GET unless told otherwise, and reading a PR lands nothing.
# Gating every mention of /pulls blocked reading a review's own comments --
# found while doing exactly that, in this repository.
expect allow "gh api GET a PR" 'gh api repos/o/r/pulls/4'
expect allow "gh api GET its comments" 'gh api repos/o/r/pulls/4/comments'
expect allow "gh api explicit GET" 'gh api --method GET repos/o/r/pulls'
expect allow "gh api GET with jq" 'gh api repos/o/r/pulls/4/comments --jq ".[].body"'
# ...and the writes are still gated, whichever way they are spelled.
expect deny "gh api --method POST" 'gh api --method POST repos/o/r/pulls -f title=x'
expect deny "gh api PATCH" 'gh api -X PATCH repos/o/r/pulls/4 -f state=open'
expect deny "gh api with a field implies POST" 'gh api repos/o/r/pulls --field title=x'

# gh's flag parser takes the value attached as well as separated, and the
# narrowed rule only recognised the separated form -- so `--method=POST` and
# `-XPOST` walked straight through a gate that had caught them before it was
# narrowed. Both issue a real POST.
expect deny "gh api --method=POST" 'gh api --method=POST repos/o/r/pulls'
expect deny "gh api -XPOST" 'gh api -XPOST repos/o/r/pulls'
expect deny "gh api --method=DELETE" 'gh api --method=DELETE repos/o/r/pulls/1'
expect deny "gh api -XPATCH" 'gh api -XPATCH repos/o/r/pulls/1'
# Field flags take their value attached too.
expect deny "gh api -ftitle=x" 'gh api repos/o/r/pulls -ftitle=x'
expect deny "gh api --field=title=x" 'gh api repos/o/r/pulls --field=title=x'
expect deny "gh api --input" 'gh api repos/o/r/pulls --input body.json'
# ...and an attached GET is still a read.
expect allow "gh api --method=GET" 'gh api --method=GET repos/o/r/pulls'
expect allow "gh api -XGET" 'gh api -XGET repos/o/r/pulls/4'

# gh does not validate or normalise the method value, and the shell has
# already collapsed repeated spaces before gh sees the argument -- so these
# are the same request as the forms above, spelled differently.
expect deny "gh api --method<2 spaces>POST" 'gh api --method  POST repos/o/r/pulls'
expect deny "gh api lowercase post" 'gh api --method post repos/o/r/pulls'
expect deny "gh api -X lowercase" 'gh api -X delete repos/o/r/pulls/1'
expect deny "gh api --method=patch" 'gh api --method=patch repos/o/r/pulls/1'
# ...and a read stays a read however it is spaced or cased.
expect allow "gh api lowercase get" 'gh api --method get repos/o/r/pulls'

# Quoting is stripped by the shell before gh sees it, so a quoted method is
# the same request. Chasing spellings missed this one after three revisions,
# which is why the rule is now inverted: gated unless provably a read.
expect deny "gh api -X quoted PUT" 'gh api -X "PUT" repos/o/r/pulls/4/merge'
expect deny "gh api --method quoted POST" 'gh api --method "POST" repos/o/r/pulls'
expect deny "gh api single-quoted DELETE" 'gh api -X '\''DELETE'\'' repos/o/r/pulls/1'
# A method nobody has thought of is gated too, rather than allowed by
# default. That is the whole point of the inversion.
expect deny "gh api unknown method" 'gh api -X FROBNICATE repos/o/r/pulls'
expect deny "gh api merge with no fields" 'gh api --method PUT repos/o/r/pulls/4/merge'
# ...and the reads stay reads, quoted or not.
expect allow "gh api quoted GET" 'gh api -X "GET" repos/o/r/pulls/4'
expect allow "gh api HEAD" 'gh api --method HEAD repos/o/r/pulls'

# gh's flag parser takes the LAST occurrence of a repeated flag, so a
# throwaway GET in front of a real write is still a write. Asking whether the
# command mentioned GET anywhere turned every gated write back into a read.
expect deny "repeated --method, last wins" 'gh api --method GET --method PUT repos/o/r/pulls/4/merge'
expect deny "repeated -X, last wins" 'gh api -X GET repos/o/r/pulls/4/merge -X PUT'
expect deny "GET then attached write" 'gh api -X GET repos/o/r/pulls -XDELETE'
# ...and the converse: a write followed by a read really is a read, because
# that is what gh would send.
expect allow "write then GET, last wins" 'gh api -X PUT repos/o/r/pulls/4 -X GET'

echo "--- never gated ---"
expect allow "git status" 'git status'
expect allow "git commit" 'git commit -m "feat: x"'
expect allow "git fetch" 'git fetch origin'
expect allow "gh pr list" 'gh pr list'
expect allow "gh pr view" 'gh pr view 42'
expect allow "gh pr diff" 'gh pr diff 42'
expect allow "ls" 'ls -la'
expect allow "outside a git repo" 'git push' /tmp

echo "--- new commit re-arms the gate ---"
mark "$SHA"
echo y >> "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm "feat: more"
expect deny "push after new commit" 'git push'
mark "$(git -C "$REPO" rev-parse HEAD)"
expect allow "push after re-review" 'git push'

echo "--- per-repo opt-out ---"
unmark
touch "$REPO/.git/lastlight-review-gate-off"
expect allow "push (gate off)" 'git push'
expect allow "gh pr create (gate off)" 'gh pr create --fill'
rm -f "$REPO/.git/lastlight-review-gate-off"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
