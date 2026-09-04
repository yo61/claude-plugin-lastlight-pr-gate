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
GATE="${GATE:-$HOME/.claude/hooks/lastlight-review-gate.sh}"
pass=0
fail=0

TMP=$(mktemp -d)
REPO=$TMP/repo
mkdir -p "$REPO"
git init -q "$REPO"
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
