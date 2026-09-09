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
  local cmd=$1 fallback=$2 explicit=${3:-} p
  # The command's OWN directory, when the caller could parse one, rather than
  # any `git -C` found in the surrounding text. This used to scan the whole
  # accumulated prefix, so an unrelated `git -C ../elsewhere status` earlier on
  # the line decided where a later push was judged -- and with one opted-out
  # repository anywhere on disk that was a one-line bypass.
  p=$explicit
  if [[ -z $p ]]; then
    p=$(sed -E -n 's/.*(^|[^[:alnum:]_-])(cd|pushd)[[:space:]]+([^;&|)]*).*/\3/p' <<< "$cmd" | head -1 | sed 's/[[:space:]]*$//')
  fi
  p=${p%\"}
  p=${p#\"}
  p=${p%\'}
  p=${p#\'}
  p=${p/#\~/$HOME}
  # A relative path is relative to where the COMMAND runs, not to wherever this
  # hook happens to have been started. `git -C . -c x=y push` resolved `.` in
  # the hook's own process directory and judged the push against a completely
  # different repository -- one that happened to have a marker.
  [[ -z $p || $p == /* ]] || p=$fallback/$p
  # ...and it has to BE a repository. A `cd` inside a closed subshell does not
  # move where a later command runs, so `(cd /tmp); git push origin main`
  # resolved /tmp, found no git dir there, and the caller returned 0 -- allowing
  # a push that bash ran in the original repository. Falling back to where the
  # command actually runs turns that into the ordinary check.
  #
  # This does not model subshells, and does not need to: the contract asks the
  # gate to recognise ordinary spellings and to fail toward the command's own
  # directory, not to track shell scope.
  if [[ -n $p && -d $p ]] && git -C "$p" rev-parse --git-dir > /dev/null 2>&1; then
    printf '%s' "$p"
  else
    printf '%s' "$fallback"
  fi
}

# Local revisions whose commits would land remotely, one per line. Empty output
# means "nothing lands" (tag-only, deletion) OR "could not tell" -- the caller
# distinguishes the two, because those must not share a verdict.
pushed_revs() {
  # WORDS, one per argument, not a string to re-split. The caller used to hand
  # over text that this function word-split again, which meant a second parse
  # that could disagree with the first -- and did, for anything quoted.
  local tok seen_remote=0 skip_next=0
  for tok in "$@"; do
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

    # A flag whose value is a SEPARATE token takes that token with it. Skipping
    # the flag alone left the value standing in for the remote, so in
    # `git push -o ci.skip origin main` the remote was read as `ci.skip` and
    # `origin` came back as a rev -- rev-parse failed on it and the gate denied
    # a push whose SHA had a valid marker. `-o ci.skip` is how a CI run gets
    # skipped, which is about as ordinary as a push gets.
    #
    # The attached spellings need nothing: `--push-option=x` is one token and
    # is already skipped as a flag below.
    case $tok in
      -o | --push-option | --repo | --receive-pack | --exec)
        skip_next=1
        continue
        ;;
      *) ;; # not a flag that carries its value separately
    esac

    # `tag <name>` is git's documented shorthand for
    # refs/tags/<name>:refs/tags/<name>. Left alone, `tag` was emitted as a rev
    # and rev-parse failed on it, so a tag push -- not gated at all, per the
    # contract -- was refused over an unresolvable ref.
    if [[ $tok == tag ]]; then
      seen_remote=1
      skip_next=1
      printf -- '-\n'
      continue
    fi

    # A force refspec keeps its `+`, and `rev-parse '+main^{commit}'` fails --
    # so the ordinary force-push spelling was denied over an unresolvable ref
    # while its SHA carried a marker. Strip it before anything reads the ref.
    tok=${tok#+}

    case $tok in
      -*) continue ;;
      *[\$\`]*)
        # A ref this cannot read. The test used to run on the whole segment, so
        # a `$` in an env assignment, a redirection target or a push-option
        # value denied a push whose refs were literal -- while telling the
        # caller to name the ref literally, which they had. Here it sees only
        # tokens that reached ref position, because flags and redirections have
        # already been skipped above.
        seen_remote=1
        printf '?\n'
        continue
        ;;
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
  # One line per shell segment, splitting on the separators the shell uses --
  # `;`, `|`, `&`, parens, a backtick, and a NEWLINE -- but only where the
  # shell would: outside quotes, unescaped.
  #
  # THE WHOLE COMMAND IS ONE BUFFER. awk resets its state at every record and
  # the shell carries quote state across newlines, so parsing line by line read
  # the closing quote of a two-line string as an opening one: everything after
  # it sat in an unterminated quote, and `echo "a<newline>b" ; git push` was
  # allowed while bash ran the push. A newline outside quotes is a separator
  # like any other; inside them it is text.
  #
  # An unterminated quote yields ONE segment: everything stays together, so a
  # method cannot be detached from its endpoint by leaving a quote open.
  awk '
    BEGIN { SQ = sprintf("%c", 39); BT = sprintf("%c", 96) }
    { buf = buf (NR > 1 ? "\n" : "") $0 }
    END {
      seg = ""
      mode = ""
      prev_ws = 1
      n = length(buf)
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        # Whether a `#` here would start a word, and so a comment. Set from the
        # PREVIOUS character, before this one is classified.
        if (i > 1) {
          pc = substr(buf, i - 1, 1)
          prev_ws = (pc == " " || pc == "\t" || pc == "\n" || pc == ";" \
            || pc == "|" || pc == "&" || pc == "(" || pc == ")") ? 1 : 0
        }
        if (mode == "sq") {
          if (c == SQ) mode = ""
          # A newline inside quotes is text, but the caller reads these segments
          # a LINE at a time -- so emitting one would let `read` split a command
          # the shell keeps whole. Carried through as a space: this scan cares
          # where the words are, not what a string says.
          seg = seg (c == "\n" ? " " : c)
        } else if (mode == "dq") {
          # A backslash still escapes inside double quotes, so a quoted \" does
          # not close the span.
          if (c == "\\" && i < n) { seg = seg c substr(buf, ++i, 1); continue }
          # ...but double quotes are NOT opaque: the shell executes $( ) and
          # backticks inside them.
          # The split leaves the outer command with a dangling quote, which
          # is an artefact of cutting here rather than anything the command
          # did -- and an unparseable segment is skipped, so a push whose ref
          # came from a quoted substitution was never judged at all. Close the
          # quote, and keep the marker character: the segment has to stay
          # parseable AND still show that an expansion was in it, because that
          # is what the refusal downstream rests on.
          if (c == "$" && i < n && substr(buf, i + 1, 1) == "(") {
            print seg "$\""; seg = ""; mode = ""; i++; continue
          }
          if (c == BT) { print seg c "\""; seg = ""; mode = ""; continue }
          if (c == "\"") mode = ""
          seg = seg (c == "\n" ? " " : c)
        } else {
          if (c == "\\" && i < n) { seg = seg c substr(buf, ++i, 1); continue }
          if (c == SQ)   { mode = "sq"; seg = seg c; continue }
          if (c == "\"") { mode = "dq"; seg = seg c; continue }
          # A newline outside quotes separates commands.
          #
          # This IS redundant with the caller, which reads segments a line at a
          # time and so splits on any newline that reaches it -- mutation
          # testing says removing it moves no assertion, and that was checked
          # against the gate rather than assumed. It stays because it is what
          # makes this function correct on its own: the split done by the
          # caller knows nothing about quotes, and the only reason it cannot
          # go wrong is that quoted newlines are turned into spaces above.
          # Two rules holding each other up is worth a line saying so.
          #
          # (No apostrophes in here. This comment sits inside a
          # single-quoted awk program, and one of them closed the string.)
          if (c == "\n" || c == ";" || c == "|" || c == "(" || c == ")") {
            print seg; seg = ""; continue
          }
          # A backtick separates, and stays on the segment it ends: the rule
          # that gates a gh call whose flags come from a substitution looks for
          # this character in the raw segment.
          if (c == BT) { print seg c; seg = ""; continue }
          # A comment, here too -- and for the opposite reason to the
          # tokenizer. A separator INSIDE a comment would split the line and
          # hand back the commented-out half as a live segment, so
          # `echo hi # && git push origin main` would be denied for a push bash
          # never runs. Denying ordinary work is the worse failure.
          if (c == "#" && (i == 1 || prev_ws)) {
            while (i <= n && substr(buf, i, 1) != "\n") i++
            i--
            continue
          }
          if (c == "&") {
            # Not every & separates. A redirection carries one -- 2>&1, >&2,
            # <&3, &>out -- and the shell strips it before the command runs.
            prv = (i > 1) ? substr(buf, i - 1, 1) : ""
            nxt = (i < n) ? substr(buf, i + 1, 1) : ""
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

# Whether this segment uses `gh api` to CREATE a pull request.
#
# That is the only `gh api` call this plugin is about. Merging is out of scope
# -- a merge delivers no new SHA to origin and triggers no review -- and reads
# are never blocked, so what remains is a POST to a /pulls collection.
#
# GATED ONLY WHEN PROVABLY A CREATE, which is the opposite of what this rule
# used to say. "Gated unless provably a read" was right while any write to
# /pulls mattered and a miss meant unreviewed code; now a miss costs one billed
# review and a false positive gets the whole gate switched off. See
# docs/gate-contract.md for the ordering that decides this.
#
# Three tests went with the old doctrine: one that treated any expansion as
# hostile (it denied ordinary reads), one that treated an unparseable segment
# as a write, and an endpoint match on /pulls/N/... that only ever caught
# merges. An unreadable call is not provably a create, and that is now the
# answer rather than a gap.
gh_api_creates_pr() {
  local seg=$1 w method="" i out
  local -a words=()
  out=$(shell_words "$seg") || return 1
  [[ -n $out ]] || return 1
  while IFS= read -r w; do words+=("$w"); done <<< "$out"

  local n=${#words[@]}
  [[ $n -gt 1 ]] || return 1

  local is_api=0 api_at=-1
  for ((i = 0; i + 1 < n; i++)); do
    if [[ ${words[i]} == gh && ${words[i + 1]} == api ]]; then
      in_command_position "$i" "${words[@]}" || continue
      is_api=1
      api_at=$i
      break
    fi
  done
  [[ $is_api -eq 1 ]] || return 1

  # A /pulls COLLECTION, not a path below one. `repos/o/r/pulls` creates;
  # `repos/o/r/pulls/4/merge` merges, and merging is not this plugin's
  # business. The query string and any redirection come off first, because gh
  # takes a query in the endpoint and the shell takes the redirection away.
  #
  # THE FIRST POSITIONAL after `gh api`, not any word that happens to end in
  # /pulls. Scanning every word meant a flag VALUE marked the call: `gh api
  # repos/o/r/issues -f body=docs/pulls` was refused, with a message about
  # opening a pull request, for a write to an endpoint this plugin does not
  # gate. Flags are skipped, and the ones taking a separate value take it too.
  local names_collection=0 endpoint k
  k=$((api_at + 2))
  while [[ $k -lt $n ]]; do
    case ${words[k]} in
      -f | -F | --field | --raw-field | --input | -H | --header | -X | --method | \
        -q | --jq | -t | --template | --hostname | --cache | -p | --preview)
        k=$((k + 2))
        ;;
      -*) k=$((k + 1)) ;;
      *) break ;;
    esac
  done
  if [[ $k -lt $n ]]; then
    endpoint=${words[k]%%[?#<>]*}
    case $endpoint in
      */pulls | pulls) names_collection=1 ;;
      *) ;; # not a pulls collection
    esac
  fi
  [[ $names_collection -eq 1 ]] || return 1

  # The method first, because it decides what the field flags MEAN. The LAST
  # one named is the one gh uses.
  for ((i = 0; i < n; i++)); do
    case ${words[i]} in
      -X | --method) [[ $((i + 1)) -lt $n ]] && method=${words[i + 1]} ;;
      -X?*) method=${words[i]#-X} ;;
      --method=*) method=${words[i]#--method=} ;;
      *) ;; # not a method flag; keep the last one seen
    esac
  done
  method=$(tr '[:lower:]' '[:upper:]' <<< "$method")

  # An explicit GET or HEAD is a read whatever follows it. gh documents that
  # with `-X GET` the -f/-F values become QUERY PARAMETERS -- its own manual
  # example is `gh api -X GET search/issues -f q=...`. Reading field flags
  # first denied those, and reads are never blocked.
  [[ $method == GET || $method == HEAD ]] && return 1

  # Now the field flags mean what they usually mean: gh POSTs when they are
  # present and nothing says otherwise, and creating a pull request needs them
  # -- title, head, base.
  for ((i = 0; i < n; i++)); do
    case ${words[i]} in
      -f* | -F* | --field* | --raw-field* | --input*) return 0 ;;
      *) ;; # not a field flag
    esac
  done

  [[ $method == POST ]]
}

# The words a shell would hand a command: quotes removed, split on unquoted
# whitespace. Same state machine as shell_segments, one level down.
#
# Used by both scans. The git test matched raw text and read the message of
# `git commit -m "fix: git push origin handling"` as a push, then took the
# rest of the prose for refspecs and denied fail-closed. A quoted string is
# ONE word here, so prose cannot look like a command.
#
# This is the difference between reading the command and reading the text of
# the command, and every bypass in this function's history has lived in that
# gap.
shell_words() {
  # The words a shell would hand a command: quotes removed, split on unquoted
  # whitespace. Same state machine as shell_segments, one level down, and the
  # same single buffer for the same reason.
  #
  # Used by every scan here. Matching raw text instead meant this gate and the
  # shell were reading different commands -- `git "push" origin HEAD` is a push
  # to one and prose to the other -- and a quoted commit message mentioning
  # pushing was read as a push and denied fail-closed. A quoted string is ONE
  # word here, so prose cannot look like a command and a quoted command cannot
  # hide from one.
  awk '
    BEGIN { SQ = sprintf("%c", 39); BT = sprintf("%c", 96) }
    { buf = buf (NR > 1 ? "\n" : "") $0 }
    END {
      w = ""; started = 0; mode = ""
      n = length(buf)
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (mode == "sq") {
          if (c == SQ) { mode = ""; continue }
          w = w c; started = 1
        } else if (mode == "dq") {
          if (c == "\\" && i < n) { w = w substr(buf, ++i, 1); started = 1; continue }
          if (c == "\"") { mode = ""; continue }
          w = w c; started = 1
        } else {
          if (c == "\\" && i < n) { w = w substr(buf, ++i, 1); started = 1; continue }
          if (c == SQ)   { mode = "sq"; started = 1; continue }
          if (c == "\"") { mode = "dq"; started = 1; continue }
          # A backtick is kept: the segmenter splits on it, so it no longer
          # has to be removed here for a command to be recognised -- and a ref
          # carrying one is how the gate knows it cannot read that ref.
          if (c == BT)   { w = w c; started = 1; continue }
          # An unquoted `#` at the START of a word begins a comment, and the
          # rest of the line is not the command. Without this its words became
          # the push argument list, so `git push origin main # --dry-run`
          # really pushed while the gate read the commented-out flag as the
          # push and allowed it. Mid-word it is an ordinary character: `a#b` is
          # one word.
          if (c == "#" && started == 0) {
            while (i <= n && substr(buf, i, 1) != "\n") i++
            continue
          }
          if (c == " " || c == "\t" || c == "\n") {
            if (started) print w
            w = ""; started = 0
            continue
          }
          w = w c; started = 1
        }
      }
      if (started) print w
      # Ends inside a quote: the caller cannot treat these words as what the
      # command would receive, because a shell would not have run this at all.
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
  # NO TEXT PRE-FILTER. There used to be one, and it decided whether the word
  # test ran at all -- so `git "push" origin HEAD`, which is a push to the shell
  # and prose to a grep, never reached the words that would have recognised it.
  # The comment claiming it merely "erred loose" was wrong: a filter that gates
  # the check is the check.
  #
  # Everything below is decided from words. The parse was never the expensive
  # part; the git work is, and that still sits behind these tests.
  # PER SEGMENT, like the push scan, and for two reasons. Handing a whole
  # command line to a function written for a segment meant `(gh pr create)`
  # tokenised as `(gh` and matched nothing. And the DIRECTORY has to come from
  # the prefix up to the call, not from the whole line: resolve_target takes
  # the last `cd` it can see, so a `cd` in a later segment -- or inside a
  # closed subshell -- decided where a PR-open was judged. Allowed when that
  # named an opted-out repository, denied when it named an unreviewed one.
  local opens=0 s pr_prefix="" opens_prefix=""
  while IFS= read -r s; do
    pr_prefix="$pr_prefix$s;"
    if [[ $opens -eq 0 ]] && { segment_opens_pr "$s" || gh_api_creates_pr "$s"; }; then
      opens=1
      opens_prefix=$pr_prefix
    fi
  done < <(shell_segments "$cmd")

  if [[ $opens -eq 1 ]]; then
    gate_pr_open "$opens_prefix" "$cwd"
  fi

  # PER INVOCATION, for the reason gh_api_creates_pr_anywhere already splits: the
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
    push_words "$seg" > /dev/null || continue
    gate_push_segment "$seg" "$prefix" "$cwd"
  done < <(shell_segments "$cmd")

  allow
}

# Whether the command opens or un-drafts a pull request, judged on words.
#
# Was a text grep anchored to the start of a line or a separator, so
# `GH_TOKEN=x gh pr create --fill` did not match it -- and a quoted spelling
# would not have either.
segment_opens_pr() {
  local seg=$1 w out i
  local -a words=()
  out=$(shell_words "$seg") || return 1
  [[ -n $out ]] || return 1
  while IFS= read -r w; do words+=("$w"); done <<< "$out"

  local n=${#words[@]}
  for ((i = 0; i + 2 < n; i++)); do
    [[ ${words[i]} == gh && ${words[i + 1]} == pr ]] || continue
    # `echo gh pr create --fill` is prose, not a PR-open. The push scan already
    # required this and the gh one did not.
    in_command_position "$i" "${words[@]}" || continue
    case ${words[i + 2]} in
      create | ready | reopen) return 0 ;;
      *) ;;
    esac
  done
  return 1
}

# Whether the word at INDEX is the command of its segment, given every word.
#
# `echo git push foo bar` and `echo gh pr create` have those words in them and
# are not commands; the refspecs taken from the first do not resolve, so it
# denied fail-closed over an unknown ref. Only assignments, a wrapper, or a
# shell keyword may precede a command.
#
# KNOWN GAP: a wrapper carrying its own arguments -- `sudo -u someone git push`
# -- is not recognised, so it is not gated. The alternative is treating every
# `git push` anywhere on a line as a command, which is what denied the echo.
# Named here rather than left to be rediscovered.
#
# One function, because the rule was about to exist in two scans, and two
# copies of a rule are two rules.
in_command_position() {
  local idx=$1
  shift
  local -a words=("$@")
  local j
  for ((j = 0; j < idx; j++)); do
    case ${words[j]} in
      *=*) ;; # VAR=value git push
      sudo | doas | env | command | exec | nohup | time | xargs) ;;
      # Shell keywords and group openers introduce a command as legitimately as
      # a wrapper does, and carry no arguments of their own.
      if | then | else | elif | while | until | do | '{' | '!') ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# The argument words of a `git push` in this segment, one per line, or
# non-zero when the segment does not invoke one.
#
# DETECTION AND EXTRACTION FROM THE SAME PARSE. Detection moved onto shell
# words one commit ago and extraction was left grepping the raw text for a
# literal `git push`, so quoting the shell strips -- `git "push" origin x` --
# was detected as a push whose arguments came back EMPTY. An empty argument
# list reads as "no explicit ref", which substitutes HEAD, and HEAD normally
# carries a marker right after a legitimate review. The gate approved a push of
# something else entirely.
#
# `git` has to BE the command, not an argument to one: `echo git push foo bar`
# has those words in it and is not a push, and the refspecs taken from it do
# not resolve, so it denied fail-closed over an unknown ref. Only assignments,
# a wrapper, or a shell keyword may precede it.
#
# KNOWN GAP: a wrapper carrying its own arguments -- `sudo -u someone git push`
# -- is not recognised, so it is not gated. The alternative is treating every
# `git push` anywhere on a line as a command, which is what denied the echo.
# Named here rather than left to be rediscovered.
push_words() {
  local seg=$1 w out i
  local -a words=()
  out=$(shell_words "$seg") || return 1
  [[ -n $out ]] || return 1
  while IFS= read -r w; do words+=("$w"); done <<< "$out"

  local n=${#words[@]} start=-1 dir="" k
  for ((i = 0; i + 1 < n; i++)); do
    [[ ${words[i]} == git ]] || continue
    in_command_position "$i" "${words[@]}" || continue

    # Skip git's global options to reach the subcommand. Recognising `push`
    # only straight after `git` meant `git -c x=y push` and
    # `git --no-pager push` were not pushes at all -- fail-open, with not even
    # the HEAD fallback running.
    #
    # The flags that take a SEPARATE value are enumerated because that set is
    # bounded and getting it wrong swallows the subcommand. The boolean ones
    # are not: anything else starting with `-` is skipped generically, so a
    # flag nobody here has heard of cannot hide the push behind it.
    k=$((i + 1))
    while [[ $k -lt $n ]]; do
      case ${words[k]} in
        -C)
          dir=${words[k + 1]:-}
          k=$((k + 2))
          ;;
        -c | --git-dir | --work-tree | --namespace | --exec-path | --super-prefix)
          k=$((k + 2))
          ;;
        -*) k=$((k + 1)) ;;
        *) break ;;
      esac
    done

    if [[ ${words[k]:-} == push ]]; then
      start=$((k + 1))
      break
    fi
  done
  [[ $start -ge 0 ]] || return 1

  # FIRST LINE is the -C directory, empty when there is none, and the argument
  # words follow. One parse answers both questions: where the push runs and
  # what it pushes. Asking a second time is how those two came to disagree.
  printf '%s\n' "$dir"
  for ((i = start; i < n; i++)); do
    printf '%s\n' "${words[i]}"
  done
}

# Whether any of these argument words is the given flag.
#
# EXACT. The first version also matched `--flag=value`, and mutation testing
# said no assertion could tell the difference -- correctly, because none of the
# flags asked about here takes a value in git. `git push --dry-run=1` is an
# error, not a dry run, so reading it as one would ALLOW a push that git was
# going to refuse anyway; not matching it gates instead. Untestable and
# strictly less safe, so it is gone rather than carried as defence in depth
# that cannot be checked.
push_has_flag() {
  local want=$1
  shift
  local a
  for a in "$@"; do
    [[ $a == "$want" ]] && return 0
  done
  return 1
}

# The verdict for ONE `git push`. Returns 0 when that push lands nothing or is
# fully reviewed; denies, and so exits, otherwise.
#
# Every "nothing lands" case here returns rather than calling `allow`. An allow
# ends the hook for the whole command line, and that is precisely how a dry run
# chained after a real push came to speak for it.
gate_push_segment() {
  local seg=$1 prefix=$2 cwd=$3 w target gitdir dir="" first=1
  local -a args=()
  while IFS= read -r w; do
    if [[ $first -eq 1 ]]; then
      dir=$w
      first=0
      continue
    fi
    [[ -n $w ]] && args+=("$w")
  done < <(push_words "$seg")

  # A dry run sends nothing, so it needs no repository state -- but it says so
  # only about ITSELF.
  push_has_flag --dry-run "${args[@]+"${args[@]}"}" && return 0

  target=$(resolve_target "$prefix" "$cwd" "$dir")
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
  push_has_flag --delete "${args[@]+"${args[@]}"}" && return 0
  push_has_flag -d "${args[@]+"${args[@]}"}" && return 0
  if push_has_flag --tags "${args[@]+"${args[@]}"}"; then
    [[ -z $(pushed_revs "${args[@]+"${args[@]}"}") ]] && return 0
  fi

  # `--all` / `--mirror` push a set this cannot enumerate from the command line.
  if push_has_flag --all "${args[@]+"${args[@]}"}" || push_has_flag --mirror "${args[@]+"${args[@]}"}"; then
    deny "$(gate_message "$(git -C "$target" rev-parse HEAD 2> /dev/null || echo HEAD)" \
      'A --all/--mirror push sends refs this gate cannot enumerate, so it cannot confirm every SHA was reviewed.')"
  fi

  local revs real
  revs=$(pushed_revs "${args[@]+"${args[@]}"}")
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
    # A ref pushed_revs could not read: it reached ref position carrying an
    # expansion, so what would land is not knowable from here. Below the
    # sentinel, the opt-out and the nothing-lands returns, because a deletion
    # or a dry run carrying one still lands nothing -- and above the marker
    # check, because a ref that cannot be read cannot be matched to a marker.
    if [[ $rev == '?' ]]; then
      deny "$(gate_message "$(git -C "$target" rev-parse HEAD 2> /dev/null || echo HEAD)" \
        'This push names a ref through a shell expansion, so the gate cannot tell which commits would land.')"
    fi
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
