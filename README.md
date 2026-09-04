# lastlight-pr-gate

**No unreviewed commit reaches a remote.** Every push must have a
[Last Light](https://github.com/nearform/lastlight) PR review recorded locally at
that exact SHA — run with Last Light's *own* review skill, pulled from npm.

A `PreToolUse` hook, so the harness enforces it.

## Why

Last Light bills **one review per head SHA** (`pr-decisions.ts`, the
`already-reviewed: we reviewed <sha>` short-circuit). So a
`push → review finds issues → fix → push → review again` cycle costs one review
per round, and a PR can easily take eight or nine rounds before it merges.

Running the identical review locally first collapses that to one round. The
review still happens server-side — that is unavoidable, and fine — but it
happens *once*, on code that has already survived the same scrutiny.

This does **not** stop Last Light reviewing. Nothing client-side can: an open,
non-draft PR sitting at an unreviewed SHA is picked up by
`check-prs-awaiting-review` within 30 minutes regardless. What this reduces is
how many unreviewed SHAs come into existence.

## Install

```bash
claude plugin install lastlight-pr-gate@yo61-skills
```

Plugin hooks load at **session start**.

Then pull the review assets once:

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/lastlight-review-sync.sh"
```

## Workflow

```bash
scripts/lastlight-review-sync.sh --check   # assets present and unmodified?
# follow ~/.claude/lastlight-review/skills/pr-review/SKILL.md against the
# three-dot diff; write .lastlight/pr-review/findings.json in its schema
scripts/lastlight-review-record.sh          # records the pass at HEAD
git push
```

**Pass bar:** `findings: []`, or every finding dismissed in
`.lastlight/pr-review/dismissed.json` as `{"<title>": "reason"}`, each reason at
least 25 characters. A disputed finding must not be able to strand a push — the
review's own bar is precision, so it can be wrong — but a dismissal has to be
*stated*, not assumed.

The marker is **SHA-keyed**, so fixing a finding produces a new SHA that needs
its own review. Iterating locally until clean is structural, not a matter of
discipline.

## What is and is not gated

Gated until a marker exists for the SHA being pushed:

- every `git push` — including `-C`, `cd`/`pushd`, subshells, refspecs, force
  pushes, and `--all`/`--mirror` (which cannot be enumerated, so they are refused)
- `gh pr create`, `gh pr ready`, `gh pr reopen`, `gh api ... /pulls`
- the GitHub MCP write tools — see below

Allowed without a review, because no new commit lands: ref deletions
(`--delete`, `:branch`), tag-only pushes, `--dry-run`, anything outside a git
repo.

Because the question is purely local ("does this SHA have a marker?"), the gate
needs **no network** and **fails closed**.

### MCP bypass

The GitHub MCP server reaches GitHub with no shell, so `create_pull_request`,
`push_files`, `create_or_update_file` and `update_pull_request` never touch the
Bash gate. They are denied outright with a pointer at the `gh` equivalent: an
MCP call addresses a repo by owner/name and has no working directory whose
marker could be checked.

## Where the review comes from

`lastlight-review-sync.sh` pulls from **npm** (`lastlight-core`), which ships
`skills/` and `workflows/` in its `files` array. Not from a git checkout, and
not via the obvious CLI commands:

| Route | Ships `pr-review`? | Coupling |
| --- | --- | --- |
| `lastlight skills install` | **No** — operator skills only | loose |
| `lastlight fork pr-review` | Yes | **Tight** — needs `--home <checkout>` |
| `npm pack lastlight-core@X` | Yes | **Loose, version-pinned** |
| `GET /admin/skills/:name` | SKILL.md only | Loose; authoritative |

- `--check` — staged tree vs npm; fails closed if anything was edited locally.
- `--deployed <url> <token>` — staged tree vs the running instance.

Skills, prompts and workflows are **configuration data** and can be overridden
per deployment via the overlay mechanism. npm is therefore the *stock baseline*;
only the running instance is authoritative. Use `--deployed` once overlays are
in play. It cannot see overrides to skill *sub-files* — the admin API serves
SKILL.md and prompts only.

## Cheaper still

The gate reduces rounds. These reduce reviews outright, and are server-side:

- **Work in drafts.** `review.skipDraft` is `true` by default — draft PRs are
  never reviewed. Iterate in draft, mark ready once.
- **The `lastlight-ignore` label** stops all Last Light activity on a PR, and
  outranks even an explicit review request.
- **`review.trigger: on-request`** means no review ever runs unless asked. It is
  settable *per repository* by committing `.lastlight/lastlight.yml` on the
  default branch — `review` is in `repoConfig.allowKeys` and clamped one-way, so
  a repo may always be more conservative.

## Escape hatches

- Per repo: `touch "$(git rev-parse --git-dir)/lastlight-review-gate-off"`
- Disable: `claude plugin disable lastlight-pr-gate@yo61-skills`

Known false positive: `grep` matches line-by-line, so a heredoc that *writes* a
script containing `git push` trips the gate. Use the per-repo opt-out, or write
the file with the Write tool.

## Tests

```bash
bash tests/lastlight-review-gate.test.sh   # 38 cases, both directions
```

The test repo deliberately has **no remote**, which proves the gate never
depended on the network.

Lint: `shellcheck scripts/*.sh tests/*.sh` and
`shfmt -i 2 -bn -ci -sr -d scripts/*.sh tests/*.sh`.

## Marketplace entry

After the first tag, add to `yo61/claude-skills`
`.claude-plugin/marketplace.json`:

```json
{
  "name": "lastlight-pr-gate",
  "source": {
    "source": "url",
    "url": "https://github.com/yo61/claude-plugin-lastlight-pr-gate.git",
    "ref": "v0.1.0"
  }
}
```
