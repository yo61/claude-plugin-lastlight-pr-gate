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

# An expansion is not a flag this scan can read, and gh sees what the shell
# produces rather than what is written here. With FLAGS='-X PUT' the first of
# these merges a pull request, and it scored as method-less -- a read -- because
# the only `-X` in the string was inside a variable name.
#
# The quoted forms are here because quoting looks like it should help and does
# not: `"$FLAGS"` stays a single word, but gh takes an attached value, so one
# word is enough to carry `-XPUT`. Confirmed against gh itself rather than
# reasoned about: `gh api repos/cli/cli "-XHEAD"` sent a HEAD request.
expect deny "flags from a variable" 'gh api repos/o/r/pulls/4/merge $FLAGS'
expect deny "flags from a quoted variable" 'gh api repos/o/r/pulls/4/merge "$FLAGS"'
expect deny "flags from a substitution" 'gh api repos/o/r/pulls/4/merge "$(cat /tmp/m)"'
expect deny "flags from a backtick" 'gh api repos/o/r/pulls/4/merge `cat /tmp/m`'
# An unquoted expansion in the path is no safer: word splitting means
# OWNER='x -XPUT y' puts a flag on the command line from inside the path.
expect deny "a variable in the path" 'gh api repos/$OWNER/$REPO/pulls'
# The cost, stated rather than hidden: a read written with a variable is
# refused too. That is the direction this rule errs in on purpose -- a refusal
# gets reported, a silent merge does not.
expect deny "...even spelled as an explicit GET" 'gh api -XGET repos/$OWNER/r/pulls'

# ...but only within the gh segment that names /pulls. The scan is per
# invocation, so an expansion in an unrelated command on the same line is not
# this rule's business.
expect allow "an expansion in another command" 'echo $HOME; gh api repos/o/r/pulls/4'

# Splitting the command on every `;&|` cut inside quotes too, and a separator
# in the quoted ENDPOINT put the method in a fragment that no longer looked
# like a gh call: `gh api '...merge?a=1&b=2' -X PUT` scored as a
# method-less read and merged the PR. gh takes query strings in the endpoint
# and GitHub ignores unknown params, so it is a live PUT.
expect deny "an & inside the quoted endpoint" \
  "gh api 'repos/o/r/pulls/4/merge?a=1&b=2' -X PUT"
expect deny "...a ; inside it" "gh api 'repos/o/r/pulls/4/merge?a=1;b=2' -X PUT"
expect deny "...a | inside it" "gh api 'repos/o/r/pulls/4/merge?a=1|b=2' -X PUT"
expect deny "...and double quotes as well" \
  'gh api "repos/o/r/pulls/4/merge?a=1&b=2" -X PUT'
# An escaped separator is not a separator either.
expect deny "an escaped separator" 'gh api repos/o/r/pulls/4/merge\;x -X PUT'
# Not every & separates: a redirection carries one, and the shell strips it
# before the command runs. Splitting there left `gh api ...merge 2>` -- a pulls
# call with no method, scored a read -- and `1 -X PUT`, which is not a gh call
# at all. So the verdict depended on where the redirect sat relative to the
# method, which is not something the shell cares about. Denied before this rule
# was narrowed, so a regression; the suite had ;, | and && but no redirect.
expect deny "a 2>&1 before the method" 'gh api repos/o/r/pulls/4/merge 2>&1 -X PUT'
expect deny "...the >&2 spelling" 'gh api repos/o/r/pulls/4/merge >&2 -X PUT'
expect deny "...the &>out spelling" 'gh api repos/o/r/pulls/4/merge &>out -X PUT'
expect deny "...the <&3 spelling" 'gh api repos/o/r/pulls/4/merge <&3 -X PUT'
expect deny "...and after the method, as before" 'gh api repos/o/r/pulls/4/merge -X PUT 2>&1'
# && and a bare & must still separate, or the split stops doing its job.
expect allow "&& still separates" 'gh api repos/o/r/pulls/4 && echo done'
expect allow "a background & still separates" 'gh api repos/o/r/pulls/4 & echo done'
expect deny "...and a write after && is still caught" \
  'gh api repos/o/r/pulls/4 && gh api repos/o/r/pulls/4/merge -X PUT'
expect allow "a redirect on a plain read" 'gh api repos/o/r/pulls/4 2>&1'
# Parens separate commands as well. Without that, `(gh api ...)` stayed one
# segment whose first word tokenised as `(gh`, which never equalled `gh`, so
# the call was not recognised as `gh api` at all and the merge scored a read.
# The spaced form was caught, because there the paren is its own word -- the
# verdict turned on a space, and the comment beside the check already claimed
# an opening paren was handled.
expect deny "a paren attached to gh" '(gh api repos/o/r/pulls/4/merge -X PUT)'
# The same shape one spelling later: a backtick substitution left the first
# word as a backtick glued to `gh`, which never equals `gh`, so the call was
# not recognised at all. `$( )` was already caught, because a paren separates.
expect deny "wrapped in backticks" '`gh api repos/o/r/pulls/4/merge -X PUT`'
# Double quotes are NOT opaque: the shell executes $( ) and backticks inside
# them. Treated as data, the whole call stayed one word -- the push grep never
# matched, and the gh check never saw `gh` next to `api`. The unquoted form was
# covered from the start and the quoted one never was, which is how these
# survived twelve rounds while the base commit denied all of them.
expect deny "a gh write inside a quoted substitution" \
  'echo "$(gh api repos/o/r/pulls/4/merge -X PUT)"'
expect deny "...assigned to a variable" \
  'RESULT="$(gh api repos/o/r/pulls -f title=x)"'
expect deny "...through a quoted backtick" \
  'echo "`gh api repos/o/r/pulls/4/merge -X PUT`"'
# A read inside one is still a read.
expect allow "a quoted substitution around a read" \
  'echo "$(gh api repos/o/r/pulls/4)"'
# ...and an ordinary quoted string with parens in it is not a command.
expect allow "parens in a plain quoted string" 'echo "hello (world)"'
expect deny "...and in a command substitution" '$(gh api repos/o/r/pulls/4/merge -X PUT)'
# Flags arriving FROM a substitution stay denied. This is why the backtick is
# dropped by the tokenizer rather than split on by the segmenter -- splitting
# takes the character out of the segment, and the rule that catches this one
# looks for it there.
expect deny "flags from a backtick, still" 'gh api repos/o/r/pulls/4/merge `cat /tmp/m`'
# A backtick-wrapped READ is denied too, which is a deliberate consequence
# rather than an accident: once recognised, it is a gh api call carrying a
# substitution, and this rule holds that such a call is not provably a read.
expect deny "a backtick-wrapped read" '`gh api repos/o/r/pulls/4`'
expect deny "...nested" '((gh api repos/o/r/pulls/4/merge -X PUT))'
expect deny "...and backgrounded" '(gh api repos/o/r/pulls/4/merge -X PUT)&'
expect deny "...the spaced form that already worked" '( gh api repos/o/r/pulls/4/merge -X PUT )'
expect deny "...a brace group" '{ gh api repos/o/r/pulls/4/merge -X PUT ; }'
# Wrapping a read in parens does not make it a write.
expect allow "a paren-wrapped read" '(gh api repos/o/r/pulls/4)'
# ...and with the ENDPOINT last, so the closing paren is what would stick to
# it. Every case above ends in a method value, where a trailing paren costs
# nothing: `PUT)` is not GET either way. Here it decides the verdict.
expect deny "a write whose endpoint ends the paren" '(gh api -X POST repos/o/r/pulls)'
expect allow "...and the read twin" '(gh api repos/o/r/pulls)'

# gh takes a query string in the endpoint and GitHub ignores unknown params, so
# `repos/o/r/pulls?x=1` IS the collection endpoint. A `?` straight after
# `pulls` matched neither pattern -- */pulls needs the word to end there,
# */pulls/* needs a slash -- so the segment was scored a read before the field
# and method checks ran, and the first of these OPENS A PULL REQUEST. The
# single-PR form stayed covered by */pulls/*, which is how the collection hole
# survived. Denied before this rule was narrowed.
expect deny "a query string, then field flags" 'gh api "repos/o/r/pulls?x=1" -f title=x -f head=b -f base=main'
expect deny "...with an explicit POST" 'gh api -X POST "repos/o/r/pulls?x=1"'
expect deny "...spelled as a full URL" 'gh api -X POST "https://api.github.com/repos/o/r/pulls?x=1"'
expect deny "...a fragment rather than a query" 'gh api -X POST "repos/o/r/pulls#f"'
# Two question marks: the second is a literal inside the query. The strip has
# to take everything from the FIRST one, or what is left still carries a `?`
# and matches no endpoint pattern.
expect deny "...a second ? inside the query" 'gh api -X POST "repos/o/r/pulls?a=1?b=2"'
# A redirection glued to the endpoint is the same hole through a different
# character: the shell takes `>out` off before gh runs, so this reaches gh as a
# POST to the collection endpoint and opens a pull request, while the word
# `repos/o/r/pulls>out` matched neither pattern and scored a read. */pulls/*
# still caught `merge>out`, which is how the collection form survived here too.
expect deny "a redirection glued to the endpoint" 'gh api repos/o/r/pulls>out -f title=x -f head=b -f base=main'
expect deny "...with an explicit POST" 'gh api repos/o/r/pulls>out -X POST'
expect deny "...an input redirection" 'gh api repos/o/r/pulls<in -X POST'
# Redirecting a READ somewhere is still a read: the strip decides what the
# endpoint is, not what the verdict is.
expect allow "a redirected read" 'gh api repos/o/r/pulls>out.json'
# ...and the single-PR form, which was already covered, so the two stay honest
# about which pattern is doing the work.
expect deny "a query on a single PR" 'gh api -X PATCH "repos/o/r/pulls/4?x=1"'
# A read with a query is still a read: what changed is the endpoint match, not
# the verdict rule.
expect allow "a read with a query string" 'gh api "repos/o/r/pulls?state=open"'
# ...and the match is on a path segment, not a substring, so this is not a
# pulls endpoint at all.
expect allow "a word that merely starts with pulls" 'gh api repos/o/r/pullsfoo -X POST'

# The shell removes a backslash-newline before it parses, so what gh receives
# has no continuation in it. Every scan in this gate is line-based -- awk
# resets per record, grep matches per line -- so a continuation split one
# invocation in two and the half carrying the method stopped looking like a gh
# call at all. Denied on one line, allowed across two.
CONT_M=repos/o/r/pulls/4/merge
expect deny "a continuation before the method" "gh api $CONT_M ${BS}${NL}  -X PUT"
expect deny "...between gh and api" "gh ${BS}${NL}  api $CONT_M -X PUT"
expect deny "...before a field flag" "gh api repos/o/r/pulls ${BS}${NL}  -f title=x"
# Inside a word, the shell joins with NOTHING: -X<join>PUT is the word -XPUT.
# Replacing the pair with a space instead would split that token and hand the
# scan a bare -X with no value.
expect deny "...inside the flag itself" "gh api $CONT_M -X${BS}${NL}PUT"
# ...and inside the flag NAME, which is where joining with a space rather than
# with nothing stops being a detail: `--met<join>hod` is `--method` to the
# shell and `--met hod` with a space, and the second names no method at all.
expect deny "...inside the flag name" "gh api $CONT_M --met${BS}${NL}hod PUT"
# More than one continuation in a single command, so joining just the first
# leaves the rest splitting the line.
expect deny "...twice in one command" \
  "gh ${BS}${NL}  api ${BS}${NL}  $CONT_M -X PUT"
# The git scan has the same blind spot and predates every gh rule here, which
# is why the join happens once in main() rather than inside the gh splitter.
expect deny "a continuation between git and push" "git ${BS}${NL}  push origin HEAD"
# ...and a read spread over two lines is still a read.
expect allow "a read over a continuation" "gh api repos/o/r/pulls/4 ${BS}${NL}  --jq .body"
# Parens inside a quoted jq filter are data, not structure.
expect allow "parens inside a jq filter" \
  "gh api repos/o/r/pulls/4 --jq '.[] | select(.x)'"
# Leaving a quote open must not detach the method: everything stays in one
# segment, which is the direction this gate errs in.
expect deny "an unterminated quote" "gh api 'repos/o/r/pulls/4/merge -X PUT"

# The reason the splitter was made quote-aware rather than the caller made
# suspicious of odd quote counts: a pipe inside quotes is how a gh READ is
# ordinarily written, and counting quotes refuses it.
expect allow "a piped jq filter is still a read" \
  "gh api repos/o/r/pulls/4 --jq '.[] | .body'"
expect allow "...double quoted too" 'gh api repos/o/r/pulls/4 --jq ".[] | .body"'
# Genuinely separate invocations must still be judged separately -- the reason
# the split exists at all.
expect deny "a read chained before a real write" \
  'gh api repos/o/r/pulls/4 ; gh api repos/o/r/pulls/4/merge -X PUT'
expect deny "a real write chained before a read" \
  'gh api repos/o/r/pulls/4/merge -X PUT ; gh api repos/o/r/pulls -X GET'

# The scan used to match flags against the segment with its quotes still in,
# while gh parses shell-stripped words -- so the two were reading different
# commands. Each of these merges or POSTs, and each was DENIED before the
# inversion narrowed this rule, so they are regressions rather than gaps.
#
# A decoy method inside a quoted --jq filter: one word to gh, three to a text
# scan, and as the last `-X` it won.
expect deny "a decoy method inside a quoted filter" \
  "gh api repos/o/r/pulls/4/merge -X PUT --jq 'x -X GET'"
# The flag itself quoted never string-equalled the flag.
expect deny "the method flag in quotes" 'gh api "--method" PUT repos/o/r/pulls/4/merge'
# The field-flag test wanted `-f` straight after whitespace; a quote sat there.
expect deny "a quoted field flag" 'gh api repos/o/r/pulls "-ftitle=x"'
# And the endpoint was matched as text, so splitting the literal across a quote
# boundary meant the segment was never examined at all.
expect deny "the endpoint split across quotes" 'gh api "repos/o/r/pul""ls/4/merge" -X PUT'

# A quoted filter that names no method is still a read -- the point is to read
# the words, not to distrust quotes.
expect allow "a quoted filter naming no method" \
  "gh api repos/o/r/pulls/4 --jq '.[] | select(.x)  '"
expect allow "a quoted endpoint on its own" 'gh api "repos/o/r/pulls/4"'
# A quoted VALUE has to survive tokenisation as its bare self. The scanner this
# replaced stripped quotes from the method explicitly; now the tokenizer does
# it, and nothing said so until a mutation that kept the quotes changed no
# verdict in this suite. `-X 'GET'` is an ordinary way to write a read.
expect allow "a quoted GET is still a read" "gh api -X 'GET' repos/o/r/pulls"
expect allow "...double quoted too" 'gh api -X "GET" repos/o/r/pulls'
expect deny "...and a quoted PUT is still a write" "gh api -X 'PUT' repos/o/r/pulls/4/merge"

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

# "Last flag wins" holds inside ONE gh call, not across a command line.
# Reading the whole string at once let a real write be cancelled by an
# unrelated read chained after it.
expect deny "write then a separate read" 'gh api repos/o/r/pulls/4/merge -X PUT ; gh api repos/o/r/other -X GET'
expect deny "write then read, &&" 'gh api repos/o/r/pulls -XPOST && gh api repos/o/r/x -X GET'
expect deny "read then write" 'gh api repos/o/r/pulls/4 -X GET ; gh api repos/o/r/pulls/4/merge -X PUT'
expect deny "write piped onward" 'gh api repos/o/r/pulls -XPOST | jq .'
# ...and a chain of genuine reads is still allowed.
expect allow "two reads chained" 'gh api repos/o/r/pulls/4 ; gh api repos/o/r/pulls/5'

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
expect deny "...and a gh write after one" \
  "echo \"a${NL}b\" ; gh api repos/o/r/pulls/4/merge -X PUT"
expect allow "...while the two-line string alone is fine" "echo \"a${NL}b\""
# A newline IS the separator when there is no `;` -- two commands on two lines.
# Without it the whole thing is one segment, `git` follows `echo hi`, and the
# command-position test correctly says that is not a command. Mutation testing
# found this: removing the newline from the separator set moved no assertion.
expect deny "a push on its own line" "echo hi${NL}git push origin HEAD"
expect deny "...and a gh write on its own line" \
  "echo hi${NL}gh api repos/o/r/pulls/4/merge -X PUT"
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
