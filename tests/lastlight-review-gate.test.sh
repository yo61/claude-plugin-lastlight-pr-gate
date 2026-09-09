#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes are the point throughout this file:
# every case is a command string handed to the gate as DATA, and the gate has to
# see the `$FLAGS` or the backtick that a real command line would carry. Letting
# any of them expand would both change what is being tested and run it -- test
# data for a guard has to stay inert, which cost this project a live `rm -rf`
# during a suite run once already.
#
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
# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
clear_inherited_config
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

# Newline and backslash, spelled once. Cases below build multi-line and
# continuation commands from these; defined here rather than beside the
# first section that needs them, so a later section cannot depend on an
# earlier one's leftovers -- an unset NL under `set -u` would abort, but a
# reordering that left it empty would quietly turn multi-line cases into
# single-line ones that pass for the wrong reason.
NL=$'\n'
BS=$'\\'

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
# `OUT="$(git push ...)"` is simply how output is captured, and it was allowed.
expect deny "a push inside a quoted substitution" 'echo "$(git push origin HEAD)"'
expect deny "...assigned to a variable" 'OUT="$(git push origin HEAD)"'
# ...and the older spelling of the same capture. The fast-path anchor class had
# no backtick in it and the segmenter split on backticks only inside double
# quotes, so this was neither matched nor isolated.
expect deny "a push in backticks" 'OUT=`git push origin HEAD`'
expect deny "...bare" '`git push origin HEAD`'
expect deny "...inside double quotes" 'echo "`git push origin HEAD`"'
expect deny "git -C repo push" "git -C $REPO push" "$OUTSIDE"
expect deny "push after a commit" 'git commit -m x && git push'

echo "--- nothing new lands: allowed without a review ---"
expect allow "delete a remote branch" 'git push origin --delete old-branch'
expect allow "delete via empty refspec" 'git push origin :old-branch'
expect allow "tags only" 'git push --tags'
expect allow "single tag refspec" 'git push origin refs/tags/v1'
expect allow "dry run" 'git push --dry-run'

# ...but only about the push carrying the flag. The arguments used to be read
# out of the whole command line, so the dry run's flags stood in for both
# pushes here and the real one went out -- the same "a real write cancelled by
# an unrelated read chained after it" the gh rule was already fixed for.
expect deny "a real push, then a dry run" 'git push origin HEAD ; git push --dry-run'
expect deny "...the dry run first" 'git push --dry-run ; git push origin HEAD'
expect deny "...a deletion after a real push" 'git push origin HEAD ; git push origin --delete tmp'
expect deny "...a deletion before one" 'git push origin --delete tmp ; git push origin HEAD'
expect deny "...a tag push alongside" 'git push --tags ; git push origin HEAD'
expect deny "...chained with &&" 'git push origin HEAD && git push --dry-run'
# Two pushes that both land nothing are still allowed: what changed is that
# each invocation answers for itself, not that chaining is suspicious.
expect allow "two harmless pushes" 'git push --dry-run ; git push origin --delete tmp'

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

echo "--- creating a pull request without a marker ---"
unmark
expect deny "gh pr create" 'gh pr create --fill'
expect deny "gh pr ready" 'gh pr ready 42'
expect deny "gh pr reopen" 'gh pr reopen 42'

# `gh api` creates a pull request by POSTing to a /pulls COLLECTION. That is
# the only gh api call this plugin is about -- see docs/gate-contract.md.
expect deny "gh api POST to the collection" 'gh api -X POST repos/o/r/pulls'
expect deny "...with field flags, which imply POST" 'gh api repos/o/r/pulls -f title=x -f head=b -f base=main'
expect deny "...a field flag with an attached value" 'gh api repos/o/r/pulls -ftitle=x'
expect deny "...--input, which also posts" 'gh api repos/o/r/pulls --input body.json'
expect deny "...the attached method spelling" 'gh api --method=POST repos/o/r/pulls'
expect deny "...and the attached short one" 'gh api -XPOST repos/o/r/pulls'
# gh takes a query string in the endpoint and GitHub ignores unknown params, so
# this is still the collection.
expect deny "...with a query string on it" 'gh api "repos/o/r/pulls?x=1" -X POST'
# Ordinary shell shapes around it, because those are what people write.
expect deny "...in parens" '(gh api -X POST repos/o/r/pulls)'
expect deny "...after an assignment" 'GH_TOKEN=x gh api -X POST repos/o/r/pulls'
expect deny "...over a line continuation" "gh api -X POST ${BS}${NL}  repos/o/r/pulls"

echo "--- reads are never blocked ---"
# This is the half that matters most now. A read delivers no SHA and triggers
# no review, so blocking one buys nothing and spends the only thing that keeps
# the gate switched on. Several of these used to be DENIED -- an endpoint built
# from a variable was refused outright -- which the contract ranks as the worst
# failure the gate can have.
expect allow "a plain read" 'gh api repos/o/r/pulls/4'
expect allow "reading the comments" 'gh api repos/o/r/pulls/4/comments'
expect allow "an explicit GET" 'gh api --method GET repos/o/r/pulls'
expect allow "a quoted GET" "gh api -X 'GET' repos/o/r/pulls"
# gh documents that with an explicit GET the -f/-F values become QUERY
# PARAMETERS -- its own manual example is `gh api -X GET search/issues -f q=...`.
# The field-flag test used to run before the method was resolved, so these were
# denied, and reads are never blocked.
expect allow "field flags on an explicit GET" 'gh api -X GET repos/o/r/pulls -f state=closed'
expect allow "...spelled --method GET" 'gh api --method GET repos/o/r/pulls -f state=closed'
# ...while field flags with no method still POST, which is how a PR is created.
expect deny "field flags with no method" 'gh api repos/o/r/pulls -f title=x'
expect deny "...and with an explicit POST" 'gh api -X POST repos/o/r/pulls -f title=x'
expect allow "an endpoint built from variables" 'gh api repos/$OWNER/$REPO/pulls'
expect allow "a jq filter with a pipe in it" "gh api repos/o/r/pulls/4 --jq '.[] | .body'"
expect allow "a read inside a substitution" 'echo "$(gh api repos/o/r/pulls)"'
expect allow "a read in backticks" '`gh api repos/o/r/pulls`'
expect allow "a read with a query string" 'gh api "repos/o/r/pulls?state=open"'
expect allow "a read redirected to a file" 'gh api repos/o/r/pulls>out.json'

echo "--- merging is not this plugin's business ---"
# A merge delivers no new SHA to origin and triggers no review of unreviewed
# work. Most of the classification in this rule existed to recognise merges,
# and it is gone; these cases exist so that it does not come back by accident.
expect allow "merging a pull request" 'gh api repos/o/r/pulls/4/merge -X PUT'
expect allow "patching one" 'gh api -X PATCH repos/o/r/pulls/4 -f state=open'
expect allow "deleting something under one" 'gh api --method=DELETE repos/o/r/pulls/4'
expect allow "gh pr merge" 'gh pr merge 42'

echo "--- never gated ---"
expect allow "git status" 'git status'
expect allow "git commit" 'git commit -m "feat: x"'
expect allow "git fetch" 'git fetch origin'
expect allow "gh pr list" 'gh pr list'
expect allow "gh pr view" 'gh pr view 42'
expect allow "gh pr diff" 'gh pr diff 42'
expect allow "ls" 'ls -la'
expect allow "outside a git repo" 'git push' /tmp

# FALSE POSITIVES, which had no coverage until one of them denied every Bash
# command in a gated repo. The scanners are line-based, so a line that ends
# inside a quote is the shape to watch: failing to tokenise it was being scored
# "writes pulls" before the segment was even checked for being a gh call.
#
# This hook runs on every Bash call. A gate that denies ordinary work does not
# get tightened, it gets turned off -- and the commit it blocked here is the
# one you have to make before you can run the review that clears it.
expect allow "a heredoc body with an apostrophe" "cat << EOF${NL}don't${NL}EOF"
expect allow "a commit message from a heredoc" \
  "git commit -m \"\$(cat <<'EOF'${NL}subject${NL}EOF${NL})\""
expect allow "a double-quoted string over two lines" "echo \"line1${NL}line2\""
expect allow "a python heredoc" "python3 - <<'PY'${NL}print(\"it's fine\")${NL}PY"
# Prose that merely mentions the endpoint is not a call to it.
expect allow "a message mentioning pulls" "git commit -m \"fix: gate repos/o/r/pulls writes\""
expect allow "grepping for the endpoint" "rg 'repos/o/r/pulls' scripts/"
# The push test used to match raw text, so a commit message mentioning pushing
# was read as a push, its words taken for refspecs, and the line denied
# fail-closed with a message about an unresolvable ref. Commit-and-push
# one-liners are ordinary, and this repository's own messages say things like
# "a PR-open must not answer for a push".
expect allow "a commit message that mentions pushing" \
  'git commit -m "fix: git push origin handling"'
# `git` has to be the command, not an argument to one.
expect allow "prose in an echo" 'echo git push foo bar'
# ...while the forms that really are commands still gate. An assignment or a
# wrapper in front does not stop it being a push.
expect deny "an assignment before it" 'GIT_TRACE=1 git push origin HEAD'
expect deny "a wrapper before it" 'env git push origin HEAD'

# awk resets its state at every record and the shell carries quote state across
# newlines, so the closing quote of a two-line string was read as an OPENING
# one -- everything after it sat in an unterminated quote and was never
# examined. The command is parsed as a single buffer now, with a newline
# separating only outside quotes, which is what it does.
expect deny "a push after a two-line string" "echo \"a${NL}b\" ; git push origin HEAD"
expect deny "...and a PR creation after one" \
  "echo \"a${NL}b\" ; gh api -X POST repos/o/r/pulls"
expect allow "...while the two-line string alone is fine" "echo \"a${NL}b\""
# A newline IS the separator when there is no `;` -- two commands on two lines.
# Without it the whole thing is one segment, `git` follows `echo hi`, and the
# command-position test correctly says that is not a command. Mutation testing
# found this: removing the newline from the separator set moved no assertion.
expect deny "a push on its own line" "echo hi${NL}git push origin HEAD"
expect deny "...and a PR creation on its own line" \
  "echo hi${NL}gh api -X POST repos/o/r/pulls"
expect allow "...two harmless lines" "echo hi${NL}echo there"
# A newline INSIDE quotes is text, and the caller reads segments a line at a
# time -- so emitting one let `read` split a command the shell keeps whole, and
# the halves parsed as an unterminated quote rather than as a push. Carried
# through as a space now, so awk alone decides where a segment ends.
expect deny "a push whose argument spans a newline" "git push \"a${NL}b\""

# The PR-open test on words rather than text, for the same reasons as the push
# one: an assignment in front, or a quoted subcommand, hid it from a grep.
expect deny "an assignment before gh pr create" 'GH_TOKEN=x gh pr create --fill'
expect deny "...a quoted subcommand" 'gh "pr" create --fill'

# Keywords and group openers introduce a command as legitimately as a wrapper.
expect deny "a push inside if/then" 'if true; then git push origin HEAD; fi'
expect deny "...inside a brace group" '{ git push origin HEAD ; }'
expect deny "...inside a while loop" 'while true; do git push origin HEAD; done'

# The text pre-filter decided whether the word test ran, and the two disagreed:
# these are pushes to the shell and prose to a grep, so they never reached the
# words that recognise them. There is no text pre-filter any more.
expect deny "a quoted subcommand" 'git "push" origin HEAD'
expect deny "...quoted mid-word" 'git pu"sh" origin HEAD'
expect deny "...with an escape in it" 'git pus\h origin HEAD'

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

echo "--- quoting must not hide which ref is being pushed ---"
# Detection moved onto shell words and extraction was left grepping the raw
# text for a literal `git push`, so anything the shell strips made the argument
# list come back EMPTY -- which reads as "no explicit ref", substitutes HEAD,
# and HEAD has a marker right after a legitimate review. The gate then approved
# a push of something else entirely.
#
# So these need a ref that is not HEAD and is not reviewed. With only HEAD in
# play the broken answer and the correct one are the same word.
git -C "$REPO" branch -q evilwork HEAD~1 2> /dev/null || true
mark "$(git -C "$REPO" rev-parse HEAD)"
expect deny "an unreviewed ref, plainly" 'git push origin evilwork'
expect deny "...with push quoted" 'git "push" origin evilwork'
expect deny "...with git quoted" '"git" push origin evilwork'
expect deny "...with the flag quoted" 'git push "--all"'
expect deny "...the flag unquoted, for scale" 'git push --all'
# ...and the things that legitimately land nothing still do.
expect allow "the reviewed HEAD still goes" 'git push origin HEAD'
expect allow "a dry run still goes" 'git push --dry-run'
expect allow "a deletion still goes" 'git push origin --delete old'
unmark
git -C "$REPO" branch -q -D evilwork

echo "--- a push whose refs come from an expansion ---"
# shell_words drops a backtick, leaving an empty word the caller filters out --
# so the push looked like it named NO ref, the gate substituted HEAD, and
# HEAD carries a marker right after a legitimate review. A push of whatever the
# substitution produced was vouched for by a review of something else.
#
# The other two spellings already failed closed for unrelated reasons: a bare
# variable does not resolve as a ref, and $( ) splits the segment. Relying on
# that is relying on an accident, so all three are asserted.
mark "$(git -C "$REPO" rev-parse HEAD)"
expect deny "a ref from a backtick" 'git push origin `echo other`'
expect deny "...from a variable" 'git push origin $BRANCH'
expect deny "...from a substitution" 'git push origin $(echo other)'
expect allow "...while a literal reviewed HEAD still goes" 'git push origin HEAD'

echo "--- a push ref from a quoted substitution ---"
# The segmenter cuts at an opening substitution even inside double quotes, so
# the outer command was emitted with a dangling quote -- unparseable, therefore
# skipped, therefore never judged. The expansion rule that would have denied it
# lives further down and never ran.
#
# `git push origin "$(git branch --show-current)"` is an ordinary thing to
# write, and it was allowed while the unquoted form was denied.
unmark
expect deny "a quoted substitution" 'git push origin "$(echo other)"'
expect deny "...a quoted backtick" 'git push origin "`echo other`"'
expect deny "...the ordinary idiom" 'git push origin "$(git branch --show-current)"'
# The unquoted forms were already denied; asserted together so the two spellings
# cannot drift apart again.
expect deny "...unquoted, for scale" 'git push origin $(echo other)'
expect deny "...a quoted variable" 'git push origin "$BRANCH"'
# A dry run still sends nothing, whatever its arguments are made of.
expect allow "a dry run with a substitution in it" 'git push --dry-run "$(echo x)"'
# ...and neither does a deletion, which lands nothing whatever its arguments
# are made of. The refusal used to run BEFORE the nothing-lands returns, the
# work sentinel and the per-repo opt-out -- so it denied a deletion, and it
# gated a repository whose opt-out was set while printing a message offering
# that same opt-out as the remedy. A refusal naming a way out that does not
# work is worse than one naming none.
expect allow "a deletion with an expansion in it" 'git push origin --delete "$BRANCH"'

# ...and the same, with HEAD REVIEWED. Above, every case denies whether or not
# the expansion is noticed, because with no marker anywhere the HEAD fallback
# denies too -- the right verdict for the wrong reason. Mutation testing found
# it. A marker at HEAD is what separates "this push names something the gate
# cannot read" from "this push is fine".
mark "$(git -C "$REPO" rev-parse HEAD)"
expect deny "a quoted substitution, with HEAD reviewed" 'git push origin "$(echo other)"'
expect allow "...while a literal HEAD still goes" 'git push origin HEAD'
unmark

echo "--- ordinary push spellings of a REVIEWED sha ---"
# Both of these denied a push whose SHA carried a valid marker, over a message
# about an unresolvable ref. Class 1 under docs/gate-contract.md, and neither
# was covered by any case here.
#
# They need HEAD reviewed. With nothing marked, the broken answer and the
# correct one are both "deny".
mark "$(git -C "$REPO" rev-parse HEAD)"
# `+refspec` is the ordinary force-push spelling; the `+` was left on the ref
# and rev-parse failed on it.
expect allow "a force refspec" 'git push origin +main'
expect allow "...with a destination" 'git push origin +main:main'
# A flag whose value is a separate token used to leave that value standing in
# for the remote, so the remote came back as a rev. `-o ci.skip` is how a CI
# run gets skipped.
expect allow "-o with a separate value" 'git push -o ci.skip origin main'
expect allow "...spelled --push-option" 'git push --push-option ci.skip origin main'
expect allow "...trailing rather than leading" 'git push origin main -o ci.skip'
expect allow "--repo with a separate value" 'git push --repo origin main'
unmark

# ...and an unreviewed ref is still caught through the same spellings, or the
# fix above would just be a hole.
expect deny "a force refspec on an unreviewed ref" 'git push origin +other'
expect deny "...behind a push option" 'git push -o ci.skip origin other'

echo "--- a trailing comment is not part of the command ---"
# The words after an unquoted `#` landed in the push argument list, so the gate
# read a commented-out flag as the pushs own and allowed a real push.
unmark
expect deny "a commented --dry-run does not excuse a push" 'git push origin main # --dry-run'
expect deny "...nor a commented --delete" 'git push origin main # --delete'
expect deny "an ordinary trailing comment changes nothing" 'git push origin main # finally'
# Mid-word a `#` is an ordinary character: `a#b` is one word, not a comment.
expect deny "a # inside a word is not a comment" 'git push origin main#tag'
# ...and it is only a comment outside quotes.
expect deny "a # inside quotes is text" 'git push origin main -o "# note"'

# The other direction, and the reason comments are handled in the SEGMENTER as
# well: a separator inside a comment would split the line and hand back the
# commented-out half as a live segment. Denying a push bash never runs is the
# class 1 failure, which the contract ranks worse than the one above.
expect allow "a commented-out push is not a push" 'echo hi # && git push origin main'
expect allow "...a whole line commented out" '# git push origin main'
expect deny "...while a live push after a comment still counts" \
  "echo hi # a note${NL}git push origin main"

echo "--- a directory that is not a repository is not the target ---"
# `cd` inside a CLOSED subshell does not move where a later command runs, so
# the push resolved somewhere with no git dir and was allowed while bash ran it
# here. Falling back to the command's own directory turns that into the
# ordinary check; the gate does not model subshells and does not need to.
expect deny "a cd in a closed subshell does not move the push" \
  '(cd /tmp); git push origin main'
expect deny "...even when the subshell cd is inside the repo" \
  '(cd . && true); git push origin main'

echo "--- a -C elsewhere must not decide where this push is judged ---"
# resolve_target preferred any `git -C <dir>` found in the accumulated prefix
# over the push itself, so an unrelated command naming another repository
# decided the verdict -- and if that repository has the opt-out set, the push
# here was allowed. The opt-out is documented as a feature, so one opted-out
# checkout anywhere on disk was a one-line bypass.
OPTOUT=$TMP/optout
mkdir -p "$OPTOUT"
git init -q -b main "$OPTOUT"
git -C "$OPTOUT" config user.email t@t
git -C "$OPTOUT" config user.name t
echo x > "$OPTOUT/f.txt"
git -C "$OPTOUT" add f.txt
git -C "$OPTOUT" commit -qm "feat: initial"
touch "$OPTOUT/.git/lastlight-review-gate-off"

unmark
expect deny "an unrelated -C does not move the verdict" \
  "git -C $OPTOUT status ; git push origin main"
# ...while a push that really is aimed at the opted-out repository still is.
expect allow "a push actually run there is opted out" "git -C $OPTOUT push origin main"
# ...and the opt-out belonging to THIS repo still works, so what changed is
# whose opt-out counts, not whether one does.
touch "$REPO/.git/lastlight-review-gate-off"
expect allow "this repo's own opt-out still applies" 'git push origin main'
rm -f "$REPO/.git/lastlight-review-gate-off"

echo "--- git's own global options must not hide the subcommand ---"
# `push` was recognised only straight after `git`, or after exactly
# `git -C <dir>`, so any other global made the segment not a push at all --
# fail-open, with not even the HEAD fallback running.
unmark
expect deny "-c between git and push" 'git -c color.ui=false push origin main'
expect deny "--no-pager between them" 'git --no-pager push origin main'
expect deny "-C and -c together" 'git -C . -c x=y push origin main'
expect deny "--git-dir with an attached value" 'git --git-dir=.git push origin main'
# A flag this list has never heard of must not hide it either.
expect deny "an unknown boolean global" 'git --literal-pathspecs push origin main'

echo "--- a PR-open is found per segment, and only when it is a command ---"
# segment_opens_pr is written for a segment and was handed the whole command
# line; shell_words does not split on separators, so `(gh pr create --fill)`
# tokenised as `(gh` and matched nothing. The base grep was anchored on those
# characters and caught it.
unmark
expect deny "gh pr create in parens" '(gh pr create --fill)'
expect deny "...straight after a semicolon" 'true;gh pr create --fill'
expect deny "...after &&" 'true && gh pr create --fill'
# ...and prose is still prose. The push scan required this and the gh one did
# not, so the rule is one function now and both ask it.
expect allow "prose mentioning gh pr create" 'echo gh pr create --fill'

echo "--- a PR-open must not answer for a push ---"
# gate_pr_open used to end the hook: every branch called allow() or deny(), and
# allow() exits. So with HEAD reviewed, a `gh pr create` allowed the open and
# the process was gone before the push loop ran -- and an unreviewed ref went
# to the remote unexamined. Needs a ref that is NOT HEAD, or "HEAD is reviewed"
# stands in for it and the case passes without testing anything.
git -C "$REPO" checkout -q -b unreviewed
echo y > "$REPO/g.txt"
git -C "$REPO" add g.txt
git -C "$REPO" commit -qm "feat: second"
git -C "$REPO" checkout -q main
# The CURRENT head, not $SHA: an earlier section commits on main, so $SHA has
# not been HEAD since then. Marking it would have left HEAD unreviewed and
# every case below would have denied -- for the right verdict and the wrong
# reason, which is the harder kind to notice.
REVIEWED_HEAD=$(git -C "$REPO" rev-parse HEAD)
mark "$REVIEWED_HEAD"

expect allow "the PR-open alone is fine when HEAD is reviewed" 'gh pr create --fill'
expect deny "...but not the unreviewed ref beside it" \
  'gh pr create --fill ; git push origin unreviewed'
expect deny "...nor with &&" 'gh pr ready 42 && git push origin unreviewed'
expect deny "...and that push alone is denied too" 'git push origin unreviewed'
expect allow "...while the reviewed HEAD still goes" 'git push origin HEAD'
unmark
git -C "$REPO" branch -q -D unreviewed

echo "--- nothing reaches a remote from a work workspace ---"
# The clone's git dir is writable by the session, so a marker in it proves
# only that something in the sandbox wrote a file. A session could record a
# review in its own clone and push from there, and the real repository would
# never see the change -- the step `land` exists to force.
#
# `expect` is this suite's helper; a plain comparison needs its own, and the
# first version of these cases called `ok`, which does not exist here -- so
# they ran silently and the count never moved.
same() {
  local label=$1 got=$2 want=$3
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$label" "$want" "$got"
  fi
}
workspace_on() { printf '%s\n' "/some/real/repo" > "$REPO/.git/lastlight-work-sandbox"; }
workspace_off() { rm -f "$REPO/.git/lastlight-work-sandbox"; }

SHA=$(git -C "$REPO" rev-parse HEAD)
workspace_on
mark "$SHA"
expect deny "a forged marker does not open the push gate" 'git push origin HEAD'
expect deny "...nor opening a PR" 'gh pr create --fill'
# The refusal names the way out rather than only refusing.
same "the refusal points at land" \
  "$(jq -n --arg c 'git push origin HEAD' --arg d "$REPO" \
    '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | "$GATE" | grep -c land)" "1"
workspace_off
# ...and with the sentinel gone the same marker works as it always did, so
# the refusal is about the workspace, not about the marker.
expect allow "the real repository is unaffected" 'git push origin HEAD'
unmark

# The opt-out used to be honoured BEFORE the sentinel, and in a work clone that
# file sits in the clone's own git dir -- writable by the session, with Bash
# auto-approved and github.com on the egress allowlist. So the gate refused a
# forged marker and took a forged opt-out, which one `touch` produced.
workspace_on
touch "$REPO/.git/lastlight-review-gate-off"
expect deny "a forged opt-out does not undo the sentinel" 'git push origin HEAD'
expect deny "...nor for opening a PR" 'gh pr create --fill'
rm -f "$REPO/.git/lastlight-review-gate-off"
workspace_off
# ...while outside a workspace the opt-out still works, which is the whole
# point of having one.
touch "$REPO/.git/lastlight-review-gate-off"
expect allow "the opt-out still opts out" 'git push origin HEAD'
# ...including for a push the gate cannot read. The expansion refusal ran above
# this check and denied anyway, while telling the caller to set the very file
# they had already set.
expect allow "...even for a push with an expansion" 'git push origin "$BRANCH"'
rm -f "$REPO/.git/lastlight-review-gate-off"

# The sentinel used to be checked inside the per-rev loop, below the early
# allows for deletions and tag-only pushes -- so from a work workspace those
# went straight through while a plain `git push` was denied. Two of them reach
# a remote: a deletion removes a branch, and a tag push uploads the tagged
# commit with its whole history, so tagging the clone's HEAD and pushing the
# tag lands unreviewed code with no marker and no `land`.
workspace_on
expect deny "a deletion does not escape a workspace" 'git push origin --delete main'
expect deny "...nor the colon form" 'git push origin :victim-branch'
expect deny "...nor a tag-only push" 'git push --tags'
expect deny "...nor an explicit tag ref" 'git push origin refs/tags/v9'
# A dry run genuinely sends nothing, from anywhere, so it stays allowed --
# refusing it would buy no safety and would just be in the way.
expect allow "a dry run is still fine" 'git push --dry-run'
# ...and a dry run chained after a real push does not make the real one fine
# either. This is how the sentinel was cleared before each push was judged on
# its own.
expect deny "a real push hidden behind a dry run" 'git push origin HEAD ; git push --dry-run'
workspace_off

# ...and outside a workspace they are all still allowed, so what changed is
# where the sentinel is checked, not what counts as landing something.
expect allow "a deletion outside a workspace" 'git push origin --delete main'
expect allow "...a tag-only push outside one" 'git push --tags'
printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
