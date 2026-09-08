# What the push gate is for

**Ensure a local review is performed before creating a PR, or before pushing
code to an existing PR.**

That sentence is the whole specification. Everything below follows from it, and
anything that does not follow from it is out of scope. This document exists
because it was not written down: seventeen rounds of review found seventeen
rounds of defects, and without a stated purpose there was no way to tell a
defect from a request for a feature the gate was never meant to have.

## Why the review is local

The review Last Light runs on the server is billed API usage, per head SHA. The
same review run locally uses the Claude subscription, already paid for. So the
gate exists to make the **free** review happen before the **billed** one is
triggered. The point is not that the server review is worse — it is the
identical skill — it is that it costs money the local run does not.

This is also why every push to an open PR matters, and why fixes are batched
into one push: each new head SHA is another billed review.

## Who this is defending against

**A forgotten step.** An agent or a person, working in good faith, who pushes
before running the review — because they did not know, or were mid-flow, or the
command came from a habit older than this plugin.

**Not an attacker, and that follows from the paragraph above.** A missed push
is a COST, not a breach: unreviewed code does not escape, it just gets reviewed
on the expensive side of the line instead of the free one. Someone deliberately
evading the gate would be spending the repository owner's money to no benefit.
That is not an adversary; it is the forgotten step wearing a costume.

Nor does evasion need any cleverness:
`touch "$(git rev-parse --git-dir)/lastlight-review-gate-off"` is documented in
the README as the supported way out. A control with a published escape hatch is
not an adversarial control, and pretending otherwise costs more than it buys.

This is the calibration everything else hangs on, so it is worth being blunt
about what it excludes. These are NOT defects:

```
gh api "repos/o/r/pul""ls/4/merge" -X PUT      # endpoint split across quotes
gh api repos/o/r/pulls/4/merge -X PUT --jq 'x -X GET'   # decoy method
gh api repos/o/r/pulls/4/merge 2>&1 -X PUT     # method behind a redirection
`gh api repos/o/r/pulls/4/merge -X PUT`        # wrapped in a substitution
```

Nobody writes those by accident. They are evasion, and evasion is out of scope.

## What is gated

Two things, because the purpose names two things:

1. **A `git push` that would land new commits on a remote.**
2. **Creating or un-drafting a pull request** — `gh pr create`, `gh pr ready`,
   `gh pr reopen`, and the equivalent `gh api` POST to a `/pulls` collection.

The GitHub MCP write tools are denied outright rather than gated, because an
MCP call addresses a repository by owner and name and has no working directory
whose marker could be checked. That is a different decision with a different
reason, and it is in the README.

## What is not gated

- Anything that lands no new commits: `--dry-run`, ref deletions
  (`--delete`, `:branch`).
- Reads of any kind, including `gh api` reads of pull requests.
- Anything outside a git repository.
- Any command in a repository with the opt-out file set.

## Failure modes, in order of how much they matter

**1. Denying ordinary work.** This is the worst outcome, and it is not a
usability complaint. A gate that blocks a normal commit-and-push gets switched
off, and then *no* review happens, ever, in that repository. A false positive
does not degrade the purpose — it inverts it.

Two of these shipped in this branch before being caught: every multi-line Bash
command was denied for a while, and so was any commit whose message mentioned
pushing.

**2. Missing a push of unreviewed code.** The thing the gate is for, and still
only a cost. Last Light reviews the PR server-side on the `pr.opened` webhook
and on the 30-minute sweep, so a miss means the review happens anyway and is
charged for. Worth fixing; never worth denying ordinary work to prevent, since
a gate someone has switched off charges for every push rather than one.

**3. Missing a deliberate evasion.** Out of scope. Whoever evades it pays for
the review they avoided, and there is a documented opt-out for anyone who wants
one honestly.

That ordering is the useful part of this document. It is the one that was
implicitly reversed for most of the branch.

## How much shell does the gate model?

Enough to recognise the spellings ordinary use produces, and no further.

In scope, because agents and people write these without thinking about the
gate:

| Spelling | Example |
|---|---|
| quoting | `git commit -m "fix: git push handling" && git push` |
| separators | `;` `&&` `\|\|` `&` `(` `)` and a newline |
| line continuations | `git push \`<newline>`  origin HEAD` |
| assignments and wrappers | `GIT_TRACE=1 git push`, `env git push` |
| shell keywords | `if …; then git push; fi`, `{ git push; }` |
| capturing output | `OUT="$(git push origin HEAD)"` |
| git's own options | `git -C dir push`, `git -c x=y push`, `git --no-pager push` |
| directory changes | `cd repo && git push` |

Out of scope, and deliberately so:

- Wrappers that carry their own arguments (`sudo -u someone git push`).
- A command or endpoint assembled entirely from a variable.
- Anything constructed to look unlike what it is.

**Detection and extraction come from one parse.** Recognising a command one way
and reading its arguments another is how this gate came to identify a push
correctly and then check the wrong ref against a marker. One parse, so there is
no second one to disagree with.

**When a push is recognised but its refs cannot be read, deny.** This is the
one place the gate errs toward refusing, and it is narrow on purpose: it
applies only once something has been positively identified as a push. The
recovery is to name the ref literally, which costs the caller one edit.

## Open questions — decisions, not implementation

These are genuinely undecided, and the current code has an answer that nobody
chose deliberately.

**1. Is merging a pull request in scope?** The purpose says "creating a PR" and
"pushing code to an existing PR". Merging is neither. The gate currently gates
`gh api .../pulls/N/merge`, and most of the complexity in the `gh api` path
exists to classify merges. If merging is out of scope, that machinery goes.

**2. Are tag pushes in scope?** `git push --tags` is currently allowed as
"nothing new lands", which is true of a repository whose commits arrived
through reviewed pushes and false of one that has its own. Tagging a commit and
pushing the tag uploads that commit and its history.

**3. Should the `gh` path ask rather than decide?** A `PreToolUse` hook can
return `ask`. If evasion is out of scope and false positives are the primary
failure, a prompt is a better fit than a shell parser: being wrong costs one
keypress instead of either a silent miss or a blocked workflow. This would
delete most of the `gh api` classification. Raised as issue #5.

**4. How much friction is a gated read worth?** `gh api repos/$OWNER/x/pulls`
is a read, and it is currently denied because the expansion makes the call
unreadable. Under failure-mode ordering above, that is the wrong trade.

## How to use this document

When a review reports a finding on this gate, the first question is which
failure mode it belongs to. A finding in class 3 is closed as out of scope with
a pointer here. A finding in class 1 is fixed before anything else.

If a finding is genuinely a request to change the purpose, it changes this file
first.
