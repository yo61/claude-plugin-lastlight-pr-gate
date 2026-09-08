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
  done < <(gh_api_segments "$cmd")
  return 1
}

# One line per shell segment, splitting on `;`, `&` and `|` only where the
# shell would: outside quotes, unescaped.
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
gh_api_segments() {
  awk '
    BEGIN { SQ = sprintf("%c", 39) }
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
          if (c == "\"") mode = ""
          seg = seg c
        } else {
          if (c == "\\" && i < n) { seg = seg c substr($0, ++i, 1); continue }
          if (c == SQ)   { mode = "sq"; seg = seg c; continue }
          if (c == "\"") { mode = "dq"; seg = seg c; continue }
          if (c == ";" || c == "&" || c == "|") { print seg; seg = ""; continue }
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
gh_api_segment_writes() {
  local seg=$1 method

  grep -Eq '(^|[;|&(])[[:space:]]*gh[[:space:]]+api[^;|&]*(/pulls|repos/[^[:space:]]*/pulls)' \
    <<< "$seg" || return 1

  # An expansion can be anything, so the scan below is reading a command that
  # is not the one gh will receive. `gh api repos/o/r/pulls/4/merge $FLAGS`
  # has no literal flag, scores as method-less, and merges the PR ungated --
  # the silent-allow failure this rule was inverted to end.
  #
  # Quoting does not help, which is the part worth measuring rather than
  # assuming: `"$FLAGS"` stays one word, but gh takes an attached value, so
  # `"-XPUT"` as a single argument is a PUT. Confirmed on the wire against
  # gh -- `gh api repos/cli/cli "-XHEAD"` sent `HEAD /repos/cli/cli`. (The
  # separated form `"-X PUT"` does die, at Go's http layer, on the leading
  # space -- but that is one spelling of several, and spelling-by-spelling is
  # exactly how this rule failed four times.)
  #
  # WHAT THIS STILL DOES NOT COVER, and it is the same shape: an expansion can
  # hide the ENDPOINT too, and `gh api "repos/o/r/$THING"` never matches the
  # test above, so it is never examined. Widening the endpoint match to every
  # `gh api` carrying an expansion would close it and would also gate ordinary
  # issue and repo reads on every Bash call. That is a change to what this
  # function is for, and it is left for its own decision rather than folded in
  # behind a bug fix.
  grep -q '[$`]' <<< "$seg" && return 0

  # Field flags make gh POST on its own, whatever the method says. `-ftitle=x`
  # carries its value with no separator, so these are matched on the flag.
  grep -Eq '(^|[[:space:]])(-[fF]|--field|--raw-field|--input)' <<< "$seg" && return 0

  method=$(gh_api_last_method "$seg")
  [[ -z $method || $method == GET || $method == HEAD ]] && return 1
  return 0
}

# The method gh would actually use: the LAST one named, or empty if none is.
#
# Asking whether the command mentions GET anywhere was wrong. gh's flag parser
# takes the last occurrence of a repeated flag, so `--method GET --method PUT`
# sends a PUT -- and prepending a throwaway `--method GET` turned every gated
# write back into a read. Verified on the wire, not assumed.
#
# Word-based, so the three spellings are handled where they differ rather than
# by a pattern that has to cover all of them at once: `-X PUT`, `-XPUT` and
# `--method=PUT`. Quotes are stripped because the shell strips them before gh
# sees the value.
gh_api_last_method() {
  awk '{
    m = ""
    for (i = 1; i <= NF; i++) {
      if ($i == "-X" || $i == "--method") { m = $(i + 1) }
      else if ($i ~ /^-X./) { m = substr($i, 3) }
      else if ($i ~ /^--method=/) { m = substr($i, 10) }
    }
    gsub(/["'"'"']/, "", m)
    print toupper(m)
  }' <<< "$1"
}

gate_pr_open() {
  local cmd=$1 cwd=$2 target gitdir head
  target=$(resolve_target "$cmd" "$cwd")
  [[ -n $target && -d $target ]] || allow
  gitdir=$(git -C "$target" rev-parse --git-dir 2> /dev/null) || allow
  [[ $gitdir = /* ]] || gitdir="$target/$gitdir"
  [[ -e "$gitdir/lastlight-review-gate-off" ]] && allow
  head=$(git -C "$target" rev-parse HEAD 2> /dev/null) || allow
  [[ -f "$gitdir/$WORK_SENTINEL" ]] && deny "$(work_sandbox_message "$gitdir")"
  [[ -f "$gitdir/$MARKER_DIR/$head.json" ]] && allow
  deny "$(gate_message "$head" "This opens or un-drafts a PR at ${head:0:12}, which has no local review recorded.")"
}

main() {
  command -v jq > /dev/null 2>&1 || allow

  local payload cmd cwd
  payload=$(cat)
  cmd=$(jq -r '.tool_input.command // empty' <<< "$payload" 2> /dev/null) || allow
  cwd=$(jq -r '.cwd // empty' <<< "$payload" 2> /dev/null)
  [[ -n $cmd ]] || allow

  # FAST PATH: runs on every Bash call, so all git work sits behind this.
  # PR-opening is included as belt-and-braces. Once every push is gated, HEAD
  # always has a marker by the time a PR is opened, so this adds no friction --
  # but it still catches a branch pushed BEFORE this gate existed.
  local opens=0
  grep -Eq '(^|[;|&(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|ready|reopen)([[:space:]]|$|\))' <<< "$cmd" && opens=1
  gh_api_writes_pulls "$cmd" && opens=1
  if [[ $opens -eq 0 ]]; then
    grep -Eq '(^|[;|&(])[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$|\))' <<< "$cmd" || allow
  fi

  local args
  args=$(push_args "$cmd")

  if [[ $opens -eq 1 ]]; then
    gate_pr_open "$cmd" "$cwd"
  fi

  # A dry run sends nothing at all, from anywhere, so it is decided before any
  # repository state is looked at.
  grep -Eq '(^|[[:space:]])--dry-run([[:space:]]|$)' <<< "$args" && allow

  local target gitdir
  target=$(resolve_target "$cmd" "$cwd")
  [[ -n $target && -d $target ]] || allow
  gitdir=$(git -C "$target" rev-parse --git-dir 2> /dev/null) || allow
  [[ $gitdir = /* ]] || gitdir="$target/$gitdir"
  [[ -e "$gitdir/lastlight-review-gate-off" ]] && allow

  # BEFORE the nothing-lands allows, which is where this used to sit behind.
  # The sentinel says nothing reaches a remote from a work workspace, and the
  # allows below were letting two things through that do: a deletion removes a
  # remote branch, and a tag push uploads the tagged commit with its whole
  # history -- so tagging the clone's HEAD and pushing the tag lands unreviewed
  # code with no marker and no `land`. "A tag-only push lands nothing new" holds
  # for a repository whose commits arrived through reviewed pushes; a work
  # clone has its own.
  [[ -f "$gitdir/$WORK_SENTINEL" ]] && deny "$(work_sandbox_message "$gitdir")"

  # Nothing lands: deletions and tag-only pushes.
  grep -Eq '(^|[[:space:]])(--delete|-d)([[:space:]]|$)' <<< "$args" && allow
  if grep -Eq '(^|[[:space:]])--tags([[:space:]]|$)' <<< "$args"; then
    [[ -z $(pushed_revs "$args") ]] && allow
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
    [[ -n $real ]] || allow
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
    if [[ -f "$gitdir/$WORK_SENTINEL" ]]; then
      deny "$(work_sandbox_message "$gitdir")"
    fi
    if [[ ! -f "$gitdir/$MARKER_DIR/$sha.json" ]]; then
      deny "$(gate_message "$sha" "${sha:0:12} (${rev}) has no local review recorded, and pushing it puts an unreviewed SHA on the remote.")"
    fi
  done <<< "$revs"

  allow
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
