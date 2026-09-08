#!/usr/bin/env bash
# Gate: no unreviewed SHA reaches a remote.
#
# GOAL (Robin, 2026-09-04): "I want to prevent unreviewed SHAs getting pushed --
# anything that lands remotely will be reviewed, I accept that."
#
# So this is NOT conditional on a PR existing. Every commit that lands on a
# remote must first have been reviewed locally at that exact SHA, because
# anything on a remote is eventually reviewed by Last Light: the `pr.opened`
# webhook, or `check-prs-awaiting-review` sweeping every 30 minutes
# (cron-review.yaml). Reviewing locally first is what stops a round-trip.
#
# That unconditional rule is also what makes this gate DETERMINISTIC. An earlier
# version asked GitHub "does this branch have an open PR?", which needed the
# network, needed `gh`, and had to fail OPEN when either was unavailable. Asking
# only "does this SHA have a marker?" is a local filesystem question, so the gate
# now FAILS CLOSED and needs no network at all.
#
# ALLOWED without a marker, because no new commit reaches the remote:
#   - deleting a ref (`--delete`, or a `:branch` refspec with an empty source)
#   - pushing tags only (`--tags`, or a `refs/tags/...` refspec)
#   - a dry run (`--dry-run`)
# Also allowed: anything outside a git repo, and repos that opt out.
#
# KNOWN FALSE POSITIVE: `grep` matches line-by-line, so a heredoc that WRITES a
# script containing `git push` trips this. Rare, and recoverable -- use the
# per-repo opt-out, or write the file with the Write tool instead.
#
# Marker: .git/lastlight-local-review/<sha>.json, written by
# lastlight-review-record.sh, which enforces the pass bar. Keyed by SHA, so a new
# commit, amend or rebase correctly re-arms the gate -- which is what makes
# "iterate locally until clean" structural rather than a matter of discipline:
# fixing a finding produces a new SHA, and the new SHA needs its own review.
#
# Opt out for a repo: touch "$(git rev-parse --git-dir)/lastlight-review-gate-off"
#
# See ~/knowledge/lastlight/knowledge.md
set -euo pipefail

# Sibling scripts are addressed relative to this file, so the guidance in a deny
# message stays correct whether this is installed under ~/.claude/hooks or
# inside a plugin (where it lives at $CLAUDE_PLUGIN_ROOT/scripts).
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SELF_DIR

readonly MARKER_DIR=lastlight-local-review

# Written into a work clone by lastlight-work-sandbox.sh. A push from there is
# refused whatever markers it holds: the clone's git dir is writable by the
# session, so a marker in it proves nothing, and the documented way out of a
# workspace is `land` -- which fast-forwards into the real repository, where the
# review is then run and recorded.
readonly WORK_SENTINEL=lastlight-work-sandbox

work_sandbox_message() {
  local from
  from=$(cat "$1/$WORK_SENTINEL" 2> /dev/null || printf 'the real repository')
  printf '%s' "This is a work sandbox workspace, and nothing reaches a remote from here.

The clone's git dir is writable by this session, so a review recorded in it
proves nothing about the code -- it proves only that something in the sandbox
wrote a file. The way out is to land the work and review it where the review
means something:

  ${SELF_DIR}/lastlight-work-sandbox.sh land

That fast-forwards the branch into ${from}, where the review runs against the
real repository and the push gate opens for that SHA."
}

allow() { exit 0; }

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# `sed -E` throughout: BSD sed's BRE has no `\|` alternation (a GNU extension),
# so `\(cd\|pushd\)` silently matches NOTHING on macOS -- which is exactly how
# `cd repo && git push` leaked past an earlier version of this gate.
resolve_target() {
  local cmd=$1 fallback=$2 p
  p=$(sed -E -n 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:];&|)]*).*/\1/p' <<< "$cmd" | head -1)
  if [[ -z $p ]]; then
    p=$(sed -E -n 's/.*(^|[^[:alnum:]_-])(cd|pushd)[[:space:]]+([^;&|)]*).*/\3/p' <<< "$cmd" | head -1 | sed 's/[[:space:]]*$//')
  fi
  p=${p%\"}
  p=${p#\"}
  p=${p%\'}
  p=${p#\'}
  p=${p/#\~/$HOME}
  if [[ -n $p && -d $p ]]; then printf '%s' "$p"; else printf '%s' "$fallback"; fi
}

# Arguments belonging to the `git push`, up to the next command separator.
push_args() {
  sed -E -n 's/.*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push[[:space:]]*([^;&|]*).*/\2/p' <<< "$1" | head -1
}

# Local revisions whose commits would land remotely, one per line. Empty output
# means "nothing lands" (tag-only, deletion) OR "could not tell" -- the caller
# distinguishes the two, because those must not share a verdict.
pushed_revs() {
  local args=$1 tok seen_remote=0 skip_next=0
  for tok in $args; do
    # Redirections are not refs. `git push ... 2>&1 | tail` was read as a ref
    # named `2>` and denied a properly reviewed SHA, so these are stripped
    # first. A bare operator (`>`, `2>>`) takes the NEXT token as its target;
    # a joined form (`2>&1`, `>/dev/null`) carries its own.
    if [[ $skip_next -eq 1 ]]; then
      skip_next=0
      continue
    fi
    if [[ $tok =~ ^[0-9]*(\>\>|\>|\<)$ ]]; then
      skip_next=1
      continue
    fi
    [[ $tok =~ ^[0-9]*(\>|\<) ]] && continue
    [[ $tok == '&>'* ]] && continue

    case $tok in
      -*) continue ;;
      *:*)
        # `src:dst`. An empty src is a deletion; a refs/tags/ dst carries no
        # commits of its own.
        seen_remote=1
        # `-` marks an EXPLICIT ref that carries no commits. It must be
        # distinguishable from "no refs given at all", which means HEAD.
        if [[ -z ${tok%%:*} || ${tok#*:} == refs/tags/* ]]; then
          printf -- '-\n'
          continue
        fi
        printf '%s\n' "${tok%%:*}"
        ;;
      refs/tags/*)
        seen_remote=1
        printf -- '-\n'
        continue
        ;;
      *)
        # The FIRST bare token is the REMOTE, not a ref -- `git push origin main`
        # is remote `origin`, ref `main`. Treating it as a revision made
        # `git push -u origin HEAD` fail to resolve and deny a reviewed SHA.
        if [[ $seen_remote -eq 0 ]]; then
          seen_remote=1
          continue
        fi
        printf '%s\n' "$tok"
        ;;
    esac
  done
}

# Opening or un-drafting a PR surfaces HEAD for review. Once pushes are gated
# this is normally already satisfied; it exists for branches that predate the
# gate.
# Whether a `gh api` call could change a pull request.
#
# INVERTED, deliberately: gated unless the call is provably a read. Matching the
# ways of spelling a write failed four times in a row -- `--method=POST`,
# `-XPOST`, `--method  post`, then `-X "PUT"` -- because gh accepts the value
# attached, separated, quoted, in any case, and does not validate it. Each
# revision closed the spelling that had just been found and left the next one
# open, and every one of those was a silent allow.
#
# A read is a call with no field flags and either no method at all (gh defaults
# to GET) or a method that is explicitly GET or HEAD. Anything else -- an
# unrecognised spelling, a quoted value, a method this rule has never heard of
# -- is treated as a write and gated. The cost of being wrong is now a refusal
# someone will report, rather than a mutation nobody sees.
gh_api_writes_pulls() {
  local cmd=$1 seg
  # PER INVOCATION. "The last flag wins" is true inside one gh call and not
  # across a command line: reading the whole string as one let a real write be
  # cancelled by an unrelated read chained after it --
  # `gh api .../pulls/4/merge -X PUT ; gh api .../other -X GET` came out a read.
  #
  # Splitting on separators without minding quotes can cut a segment in half,
  # which at worst makes a read look like a write. That is the direction this
  # gate should err in.
  while IFS= read -r seg; do
    gh_api_segment_writes "$seg" && return 0
    # `read` returns non-zero on a final line with no newline, which skips the
    # loop body entirely -- so an unchained command, the common case, was never
    # examined at all. The trailing newline is what makes the last segment a
    # line like any other.
  done < <(shell_segments "$cmd")
  return 1
}

# One line per shell segment, splitting on `;`, `&`, `|` and parens only
# where the shell would: outside quotes, unescaped.
#
# Used by both scans. It was written for the gh rule and named for it, and
# then the git rule turned out to need exactly the same thing -- `git push
# origin HEAD ; git push --dry-run` had one invocation speaking for the
# other, which is the bug the gh rule had already been through.
#
# `tr ';&|' '\n'` split everywhere, and a separator inside a quoted endpoint cut
# the method away from the invocation carrying it --
# `gh api 'repos/o/r/pulls/4/merge?a=1&b=2' -X PUT` became a method-less read
# plus a fragment with no `gh api` in it, and the merge went ungated. Verified
# against this gate: allowed before, denied after.
#
# Counting quotes and refusing an odd count closes that too, and refuses
# `--jq '.[] | .body'` with it, which is how a gh READ is ordinarily written.
# So the splitter is quote-aware instead of the caller being suspicious.
#
# An unterminated quote yields ONE segment: everything stays together, so a
# method cannot be detached from its endpoint by leaving a quote open. That is
# the direction this gate errs in.
shell_segments() {
  awk '
    BEGIN { SQ = sprintf("%c", 39); BT = sprintf("%c", 96) }
    {
      seg = ""
      mode = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (mode == "sq") {
          if (c == SQ) mode = ""
          seg = seg c
        } else if (mode == "dq") {
          # A backslash still escapes inside double quotes, so a quoted \" does
          # not close the span.
          if (c == "\\" && i < n) { seg = seg c substr($0, ++i, 1); continue }
          # ...but double quotes are NOT opaque: the shell executes $( ) and
          # backticks inside them. Treating the whole span as data left
          # `OUT="$(git push origin HEAD)"` as one word, where the push grep
          # never matched and the gh check never saw `gh` next to `api`. Both
          # were denied before this rule was rewritten, and capturing output
          # that way is entirely ordinary.
          #
          # Drop out of quoted mode with the separator, so the body is read the
          # way the shell reads it. What follows the substitution is then read
          # unquoted too, which can split more than the shell would -- that
          # direction only adds segments to look at.
          if (c == "$" && i < n && substr($0, i + 1, 1) == "(") {
            print seg; seg = ""; mode = ""; i++; continue
          }
          if (c == BT) { print seg; seg = ""; mode = ""; continue }
          if (c == "\"") mode = ""
          seg = seg c
        } else {
          if (c == "\\" && i < n) { seg = seg c substr($0, ++i, 1); continue }
          if (c == SQ)   { mode = "sq"; seg = seg c; continue }
          if (c == "\"") { mode = "dq"; seg = seg c; continue }
          # Parens separate commands too. Without them `(gh api ...)` stayed
          # one segment whose first word tokenised as `(gh`, which never
          # equalled `gh`, so the invocation was not recognised as gh api at
          # all and a merge was scored a read. The spaced form `( gh api ...`
          # was caught, because there the paren is its own word -- the verdict
          # turned on a space.
          if (c == ";" || c == "|" || c == "(" || c == ")") { print seg; seg = ""; continue }
          if (c == "&") {
            # Not every & separates. A redirection carries one -- 2>&1, >&2,
            # <&3, &>out -- and the shell strips it before the command runs,
            # so splitting there cut the method off a call that still had it.
            prv = (i > 1) ? substr($0, i - 1, 1) : ""
            nxt = (i < n) ? substr($0, i + 1, 1) : ""
            if (prv == ">" || prv == "<" || nxt == ">") { seg = seg c; continue }
            print seg; seg = ""; continue
          }
          seg = seg c
        }
      }
      print seg
    }
  ' <<< "$1"
}

# Whether ONE invocation could change a pull request.
#
# Gated unless provably a read: no field flags, and either no method at all (gh
# defaults to GET) or a method that is explicitly GET or HEAD. An unrecognised
# spelling, a quoted value, or a method nobody has thought of is a write.
# Whether ONE invocation could change a pull request.
#
# Gated unless provably a read: no field flags, and either no method at all (gh
# defaults to GET) or a method that is explicitly GET or HEAD. An unrecognised
# spelling, a value this rule has never heard of, or anything it cannot read at
# all is a write.
#
# Judged on the WORDS gh receives. Matching against the raw segment meant this
# and gh were reading different commands: `"--method" PUT` never string-equals
# `--method`, `"-ftitle=x"` has a quote where the scan wanted whitespace, and a
# decoy `-X GET` inside a quoted --jq filter looked like the last method while
# gh sent the PUT beside it. All three merged pull requests, and all three were
# denied before the inversion narrowed this rule -- regressions, not gaps.
gh_api_segment_writes() {
  local seg=$1 w method="" i out unterminated=0
  local -a words=()
  # Command substitution, not process substitution: this needs the tokenizer's
  # exit status. An unterminated quote swallows the rest of the line into one
  # word -- `gh api 'repos/o/r/pulls/4/merge -X PUT` then carries no `-X` word
  # at all and scored as a read.
  #
  # Recorded here and acted on BELOW, once this is known to be a gh api call
  # naming a pulls endpoint. Returning "writes pulls" here judged every line
  # that ends inside a quote, and the scanners are line-based: a heredoc body
  # containing an apostrophe, the first line of `git commit -m "$(cat <<'EOF'`,
  # a two-line double-quoted string. Each denied the whole Bash command, saying
  # it opened a pull request. `echo "line1<newline>line2"` was denied. This hook
  # runs on every Bash call, so it blocked the commit that has to happen before
  # the review that would clear the gate.
  out=$(gh_api_words "$seg") || unterminated=1
  if [[ -n $out ]]; then
    while IFS= read -r w; do words+=("$w"); done <<< "$out"
  fi
  local n=${#words[@]}
  [[ $n -gt 1 ]] || return 1

  # `gh api`, however the segment reaches it -- behind `sudo`, an env
  # assignment, an opening paren.
  local is_api=0
  for ((i = 0; i + 1 < n; i++)); do
    if [[ ${words[i]} == gh && ${words[i + 1]} == api ]]; then
      is_api=1
      break
    fi
  done
  [[ $is_api -eq 1 ]] || return 1

  # A pulls endpoint, as a whole word. Splitting the literal across a quote
  # boundary -- `"repos/o/r/pul""ls/4"` -- hid it from the old text match.
  #
  # The query string comes off first. gh takes one in the endpoint and GitHub
  # ignores unknown params, so `repos/o/r/pulls?x=1` IS the collection
  # endpoint -- and a `?` straight after `pulls` matched neither pattern, so
  # `gh api "repos/o/r/pulls?x=1" -f title=x -f head=b -f base=main` scored a
  # read and opened a pull request. The single-PR form stayed covered by
  # */pulls/*, which is why this survived: the hole was the collection.
  #
  # The inversion had been applied to the method spelling and not to this one.
  # An endpoint spelling the rule has not heard of must not come out a read.
  local names_pulls=0 endpoint
  for ((i = 0; i < n; i++)); do
    # Everything the shell or a URL would cut the endpoint at. `?` and `#`
    # belong to the URL; `>` and `<` are redirections the shell removes before
    # gh runs, so `repos/o/r/pulls>out` IS the collection endpoint and matched
    # neither pattern. A set rather than a chain of strips, so the next
    # character of this kind is a character and not another line.
    endpoint=${words[i]%%[?#<>]*}
    case $endpoint in
      */pulls | */pulls/* | pulls | pulls/*)
        names_pulls=1
        break
        ;;
      *) ;; # not an endpoint word
    esac
  done
  [[ $names_pulls -eq 1 ]] || return 1

  # NOW the tokenizer's verdict matters. The words above were enough to
  # recognise the call; nothing after this point can be read off a line that
  # ends mid-quote, so it is not provably a read.
  [[ $unterminated -eq 1 ]] && return 0

  # An expansion can be anything, so the words above are not the ones gh will
  # get. `gh api repos/o/r/pulls/4/merge $FLAGS` carries no literal flag and
  # scored as method-less. Quoting does not help: gh takes an attached value,
  # so a single word `"-XPUT"` is a PUT -- confirmed on the wire,
  # `gh api repos/cli/cli "-XHEAD"` sent a HEAD request.
  #
  # WHAT THIS STILL DOES NOT COVER: an expansion can hide the ENDPOINT too, and
  # such a segment never matches the test above. Closing that means gating
  # every `gh api` carrying an expansion, ordinary issue and repo reads
  # included. That is a change to what this function is for, and is left for
  # its own decision rather than folded in behind a bug fix.
  grep -q '[$`]' <<< "$seg" && return 0

  # Field flags make gh POST on its own, whatever the method says, and they
  # take their value attached -- so this matches on the flag, not the word.
  for ((i = 0; i < n; i++)); do
    case ${words[i]} in
      -f* | -F* | --field* | --raw-field* | --input*) return 0 ;;
      *) ;; # not a field flag
    esac
  done

  # The method gh would actually use: the LAST one named, or empty if none is.
  # Asking whether the command mentions GET anywhere was wrong -- gh's parser
  # takes the last occurrence of a repeated flag, so a throwaway `--method GET`
  # in front turned every gated write back into a read. Verified on the wire.
  for ((i = 0; i < n; i++)); do
    case ${words[i]} in
      -X | --method) [[ $((i + 1)) -lt $n ]] && method=${words[i + 1]} ;;
      -X?*) method=${words[i]#-X} ;;
      --method=*) method=${words[i]#--method=} ;;
      *) ;; # not a method flag; keep the last one seen
    esac
  done
  method=$(tr '[:lower:]' '[:upper:]' <<< "$method")

  [[ -z $method || $method == GET || $method == HEAD ]] && return 1
  return 0
}

# The words a shell would hand gh: quotes removed, split on unquoted
# whitespace. Same state machine as shell_segments, one level down.
#
# This is the difference between reading the command and reading the text of
# the command, and every bypass in this function's history has lived in that
# gap.
gh_api_words() {
  awk '
    BEGIN { SQ = sprintf("%c", 39); BT = sprintf("%c", 96) }
    {
      w = ""; started = 0; mode = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (mode == "sq") {
          if (c == SQ) { mode = ""; continue }
          w = w c; started = 1
        } else if (mode == "dq") {
          if (c == "\\" && i < n) { w = w substr($0, ++i, 1); started = 1; continue }
          if (c == "\"") { mode = ""; continue }
          w = w c; started = 1
        } else {
          if (c == "\\" && i < n) { w = w substr($0, ++i, 1); started = 1; continue }
          if (c == SQ)   { mode = "sq"; started = 1; continue }
          if (c == "\"") { mode = "dq"; started = 1; continue }
          # A backtick is command substitution, not part of the word. Left in,
          # `gh api ...` wrapped in one began with a backtick glued to `gh`,
          # which never equals `gh`, so the call went unrecognised -- the paren
          # form, one spelling later. Dropped here rather than split on in
          # shell_segments: the rule that gates a call whose flags come from a
          # substitution reads the raw segment for this character, and taking
          # it out of the segment would have traded one hole for another.
          if (c == BT)   { started = 1; continue }
          if (c == " " || c == "\t") {
            if (started) print w
            w = ""; started = 0
            continue
          }
          w = w c; started = 1
        }
      }
      if (started) print w
      # Ends inside a quote: the caller cannot treat these words as what gh
      # would receive, because a shell would not have run this at all.
      if (mode != "") exit 1
    }
  ' <<< "$1"
}

# The verdict for a PR-opening command. Returns 0 when that open is fine;
# denies, and so exits, otherwise.
#
# RETURNS rather than allowing, for the same reason gate_push_segment does. An
# allow ends the hook for the whole command line, and this one ran before the
# push loop -- so on a branch whose HEAD is reviewed,
# `gh pr create --fill ; git push origin <unreviewed-branch>` allowed the open
# and exited, and the unreviewed branch went to the remote unexamined. Every
# gate here answers for its own invocation and leaves the others to be judged.
gate_pr_open() {
  local cmd=$1 cwd=$2 target gitdir head
  target=$(resolve_target "$cmd" "$cwd")
  [[ -n $target && -d $target ]] || return 0
  gitdir=$(git -C "$target" rev-parse --git-dir 2> /dev/null) || return 0
  [[ $gitdir = /* ]] || gitdir="$target/$gitdir"
  # Sentinel first, for the reason gate_push_segment gives: in a work clone the
  # opt-out is a file the session can write, so honouring it first let one
  # `touch` undo the sentinel.
  [[ -f "$gitdir/$WORK_SENTINEL" ]] && deny "$(work_sandbox_message "$gitdir")"
  [[ -e "$gitdir/lastlight-review-gate-off" ]] && return 0
  head=$(git -C "$target" rev-parse HEAD 2> /dev/null) || return 0
  [[ -f "$gitdir/$MARKER_DIR/$head.json" ]] && return 0
  deny "$(gate_message "$head" "This opens or un-drafts a PR at ${head:0:12}, which has no local review recorded.")"
}

main() {
  command -v jq > /dev/null 2>&1 || allow

  local payload cmd cwd
  payload=$(cat)
  cmd=$(jq -r '.tool_input.command // empty' <<< "$payload" 2> /dev/null) || allow
  cwd=$(jq -r '.cwd // empty' <<< "$payload" 2> /dev/null)
  [[ -n $cmd ]] || allow

  # The shell joins a backslash-newline before it parses, so what gh and git
  # receive has no continuation in it. Everything below is line-based -- awk
  # resets per record, grep matches per line -- so a continuation split one
  # invocation in two and the half carrying the method stopped looking like a
  # gh call. Verified: `gh api .../merge -X PUT` denied on one line, allowed
  # across two, and `git \<newline> push origin HEAD` allowed while the
  # one-line form was denied. That second one predates every rule in this file.
  #
  # Joined here rather than inside the gh splitter, because the git scan needs
  # it too and there is one place where every scan can be given the same
  # command.
  #
  # REMOVED, not replaced with a space: that is what the shell does, and
  # `-X\<newline>PUT` is the single word `-XPUT`. A space would split a token
  # the shell keeps whole, which turns a write back into a read.
  cmd=${cmd//\\$'\n'/}

  # FAST PATH: runs on every Bash call, so all git work sits behind this.
  # PR-opening is included as belt-and-braces. Once every push is gated, HEAD
  # always has a marker by the time a PR is opened, so this adds no friction --
  # but it still catches a branch pushed BEFORE this gate existed.
  local opens=0
  grep -Eq '(^|[;|&(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|ready|reopen)([[:space:]]|$|\))' <<< "$cmd" && opens=1
  gh_api_writes_pulls "$cmd" && opens=1
  local has_push=0
  grep -Eq '(^|[;|&(])[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$|\))' <<< "$cmd" \
    && has_push=1
  [[ $opens -eq 1 || $has_push -eq 1 ]] || allow

  if [[ $opens -eq 1 ]]; then
    gate_pr_open "$cmd" "$cwd"
  fi

  # PER INVOCATION, for the reason gh_api_writes_pulls already splits: the
  # arguments were read out of the whole command line, so
  # `git push origin HEAD ; git push --dry-run` had the dry run's flags stand
  # in for both pushes and the real one went out. Verified -- denied alone,
  # allowed chained -- and the same chain walked past the work sentinel.
  # The segment carries the push's own flags; the PREFIX carries where it runs.
  # `cd repo && git push` puts the cd in a different segment, so a push judged
  # on its segment alone lost its target and fell back to the hook's cwd. The
  # prefix is everything up to and including this segment, which also means
  # `cd a && push ; cd b && push` resolves each to its own directory rather
  # than both to whichever cd the whole line happened to mention last.
  local seg prefix=""
  while IFS= read -r seg; do
    prefix="$prefix$seg;"
    grep -Eq '(^|[[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)' <<< "$seg" \
      || continue
    gate_push_segment "$seg" "$prefix" "$cwd"
  done < <(shell_segments "$cmd")

  allow
}

# The verdict for ONE `git push`. Returns 0 when that push lands nothing or is
# fully reviewed; denies, and so exits, otherwise.
#
# Every "nothing lands" case here returns rather than calling `allow`. An allow
# ends the hook for the whole command line, and that is precisely how a dry run
# chained after a real push came to speak for it.
gate_push_segment() {
  local seg=$1 prefix=$2 cwd=$3 args target gitdir

  args=$(push_args "$seg")

  # A dry run sends nothing, so it needs no repository state -- but it says so
  # only about ITSELF.
  grep -Eq '(^|[[:space:]])--dry-run([[:space:]]|$)' <<< "$args" && return 0

  target=$(resolve_target "$prefix" "$cwd")
  [[ -n $target && -d $target ]] || return 0
  gitdir=$(git -C "$target" rev-parse --git-dir 2> /dev/null) || return 0
  [[ $gitdir = /* ]] || gitdir="$target/$gitdir"
  # BEFORE the opt-out. In a work clone that file sits in the clone's own git
  # dir, which the session can write -- Bash is auto-approved there and
  # github.com is on the egress allowlist. The gate refused a forged marker and
  # took a forged opt-out, which one `touch` was enough to produce. Inside a
  # work clone the opt-out is just another file the session wrote.
  #
  # ...and BEFORE the nothing-lands returns. The sentinel says nothing reaches a
  # remote from a work workspace, and those returns were letting two things
  # through that do: a deletion removes a remote branch, and a tag push uploads
  # the tagged commit with its whole history -- so tagging the clone's HEAD and
  # pushing the tag lands unreviewed code with no marker and no `land`. "A
  # tag-only push lands nothing new" holds for a repository whose commits
  # arrived through reviewed pushes; a work clone has its own.
  [[ -f "$gitdir/$WORK_SENTINEL" ]] && deny "$(work_sandbox_message "$gitdir")"
  [[ -e "$gitdir/lastlight-review-gate-off" ]] && return 0

  # Nothing lands: deletions and tag-only pushes.
  grep -Eq '(^|[[:space:]])(--delete|-d)([[:space:]]|$)' <<< "$args" && return 0
  if grep -Eq '(^|[[:space:]])--tags([[:space:]]|$)' <<< "$args"; then
    [[ -z $(pushed_revs "$args") ]] && return 0
  fi

  # `--all` / `--mirror` push a set this cannot enumerate from the command line.
  if grep -Eq '(^|[[:space:]])(--all|--mirror)([[:space:]]|$)' <<< "$args"; then
    deny "$(gate_message "$(git -C "$target" rev-parse HEAD 2> /dev/null || echo HEAD)" \
      'A --all/--mirror push sends refs this gate cannot enumerate, so it cannot confirm every SHA was reviewed.')"
  fi

  local revs real
  revs=$(pushed_revs "$args")
  if [[ -z $revs ]]; then
    # No explicit ref: bare `git push` sends the current branch.
    revs=HEAD
  else
    real=$(grep -v '^-$' <<< "$revs" || true)
    # Every explicit ref was a tag or a deletion -- nothing new lands.
    [[ -n $real ]] || return 0
    revs=$real
  fi

  local rev sha
  while IFS= read -r rev; do
    [[ -n $rev ]] || continue
    if ! sha=$(git -C "$target" rev-parse --verify "$rev^{commit}" 2> /dev/null); then
      # An unresolvable ref means the gate cannot prove the SHA was reviewed.
      # Fail CLOSED -- there is no network excuse here, only an unparsed command.
      deny "$(gate_message "unknown" "Could not resolve '${rev}' to a commit, so this gate cannot confirm what would land remotely.")"
    fi
    # No sentinel check here. The one above runs before any of the
    # nothing-lands returns and `deny` exits, so a copy in this loop could
    # never fire and no test could reach it. sandbox_probe_verdict says why
    # that matters: a redundant check in a security control cannot be tested,
    # so it rots while reading as defence in depth.
    if [[ ! -f "$gitdir/$MARKER_DIR/$sha.json" ]]; then
      deny "$(gate_message "$sha" "${sha:0:12} (${rev}) has no local review recorded, and pushing it puts an unreviewed SHA on the remote.")"
    fi
  done <<< "$revs"

  return 0
}

gate_message() {
  local sha=$1 why=$2
  cat << MSG
Blocked by ~/.claude/hooks/lastlight-review-gate.sh:

${why}

Anything that lands on a remote gets reviewed by Last Light -- on the pr.opened
webhook, or by the 30-minute check-prs-awaiting-review sweep. Reviewing locally
first is what stops that becoming a round trip.

Run the SAME review Last Light would run -- it is the identical skill, executed
by a session that did not write the code:

1. Check the assets are staged and unmodified:
     ${SELF_DIR}/lastlight-review-sync.sh --check
2. Run the review:
     ${SELF_DIR}/lastlight-review-run.sh
   This is REQUIRED, not a convenience. It writes the attestation binding the
   review to this SHA and diff; the recorder refuses without one, so a
   hand-written findings.json will not be accepted.
3. Fix what it finds, or dismiss each finding with a written reason in
   .lastlight/pr-review/dismissed.json.
4. Record the pass:
     ${SELF_DIR}/lastlight-review-record.sh ${sha:0:12}

Then push. Batch fixes into ONE push: each new head SHA is another review.

Not gated: ref deletions, tag-only pushes, and --dry-run, since no new commit
reaches the remote.

Opt out for this repo: touch "\$(git rev-parse --git-dir)/lastlight-review-gate-off"
MSG
}

main "$@"
