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
scripts/lastlight-review-run.sh            # independent review of HEAD's diff
scripts/lastlight-review-record.sh         # records the pass at HEAD
git push
```

`lastlight-review-run.sh` is **required**, not a convenience. It runs the review
in a fresh `claude -p` session that did not write the code, and writes
`attestation.json` binding the result to the head SHA *and* a hash of the exact
diff read. The recorder refuses a marker without a matching attestation, so a
hand-written `findings.json` is not accepted — an agent cannot approve its own
work in one line.

That is not tamper-proof: whoever can write `findings.json` can write the
attestation beside it. It makes the honest path the easy path, and stops a
stale review silently vouching for new code.

**Model.** Defaults to `sonnet`, matching Last Light's own `models.default`, so
the local pass runs at the same tier as the server's rather than inheriting
whatever the invoking session used. Override with `--model <m>` or
`LASTLIGHT_REVIEW_MODEL`; the resolved value is recorded in the attestation.

**The reviewed diff is untrusted input**, so the review runs in a disposable
`git clone` of HEAD under the built-in OS sandbox: writes confined to that
workspace, credential stores denied for reading, and egress restricted to the
API. Because the blast radius is bounded structurally, the reviewer gets Bash
and can run **probes** — installing a dependency, executing a test — which is
what the skill intends and what catches bugs that reading alone does not.

Inside the workspace the reviewer may write anything; the guarantee is that
**only `findings.json` is copied back out**, and nothing it writes can reach
your real repository. That is a different property from "writes are scoped to
one path", which describes only the unsandboxed fallback below.

The containment is **verified, not assumed**: a settings file that fails
validation is silently ignored in `-p` mode, so before granting Bash the runner
attempts an actual escape under the real policy and refuses to proceed if the
canary survives.

`LASTLIGHT_REVIEW_SANDBOX=off`, or a platform with no sandbox, falls back to a
read-only tool list with writes scoped to `findings.json` and **no probes**.
That is a weaker review, not an equivalent one — findings then rest on reading
rather than execution — so the attestation records which posture produced it.

## Checking work before you commit it

```bash
scripts/lastlight-review-run.sh --working-tree
```

Reviews uncommitted work — tracked modifications and untracked files — rather
than a committed diff. A plain clone cannot do this, since it carries committed
history only, so the workspace is assembled as: clone at HEAD → apply
`git diff HEAD` → copy untracked-but-not-ignored files.

Excluding ignored files is deliberate. It keeps `node_modules` and `.venv` out
of the copy, so it stays fast — and a probe needing dependencies installs them
*inside* the sandbox rather than inheriting whatever is on your disk. A poisoned
local dependency tree cannot execute during a review it was never copied into.

**This is advisory and cannot satisfy the push gate.** There is no commit it
could honestly vouch for, so the attestation records an empty SHA, which the
recorder compares against HEAD and refuses. That mismatch is the design, not an
oversight: a pre-commit check must never be mistakable for a review of what you
are about to push.

**Pass bar:** `findings: []`, or every finding dismissed in
`.lastlight/pr-review/dismissed.json` as `{"<title>": "reason"}`, each reason at
least 25 characters. A disputed finding must not be able to strand a push — the
review's own bar is precision, so it can be wrong — but a dismissal has to be
*stated*, not assumed.

The marker is **SHA-keyed**, so fixing a finding produces a new SHA that needs
its own review. Iterating locally until clean is structural, not a matter of
discipline.

## Sandboxing the work, not just the review

```bash
scripts/lastlight-work-sandbox.sh start -b feat/thing   # clone, confine, open a session
scripts/lastlight-work-sandbox.sh land  -b feat/thing   # fast-forward the work back
scripts/lastlight-work-sandbox.sh list                  # what is in flight
```

The review already runs on a disposable copy under an OS sandbox. The work that
*produces* the code did not: it ran in the real repository with your privileges,
so a bad edit, a stray `rm`, or a command from a poisoned dependency landed on
the only copy there was.

`start` clones the branch into `~/.lastlight/work/<repo>-<digest>/<branch>/repo` (override with
`LASTLIGHT_WORK_ROOT`), writes a policy scoped to that clone, proves the policy
holds, and opens a session there. A clone rather than a worktree: a worktree
keeps its git dir *inside* the real repository, so confining writes to the
workspace would mean granting write access to the real object store — the one
thing worth protecting. `--no-hardlinks` shares nothing.

The `<digest>` is a hash of the repository's canonical path. A basename alone is
not unique — two unrelated projects both called `api` shared a slot, so `start`
in one found the other's clone and `land` fetched an unrelated history into the
wrong repository. `land` additionally refuses any workspace whose `origin` is
not this repository, whatever put it there.

### Two layers, because neither covers the other

| Layer | Confines | Does **not** confine |
|---|---|---|
| `sandbox.filesystem` | spawned processes — the `Bash` tool | `Write`, `Edit`, `NotebookEdit` |
| `permissions` rules | every file-editing tool | processes Bash spawns |

The second is not garnish. Verified directly: with only the filesystem sandbox
in force, the `Write` tool created a file outside the workspace and reported
success. A *review* session never noticed, because it is given `Read`/`Grep`/
`Glob`/`Bash` and no way to write — but a work session lives on `Write` and
`Edit`, so for it the filesystem sandbox alone is not a boundary at all.

Neither layer confines the **environment**, and both columns above are about
files. A work session inherits the environment it was started from, so an
exported `GITHUB_TOKEN`, `GH_TOKEN` or `NPM_TOKEN` is one `printenv` away from
any process in it — and `github.com` is on that session's egress allowlist. The
denied credential *files* are the same secret by another route; denying the file
and inheriting the variable protects nothing on its own.

The review session does close this: it is launched with `env -i` and an explicit
keep-list (`sandbox_env_keep`), so nothing but configuration reaches it. The work
session does not, deliberately — it is interactive, and taking its environment
away changes how the tools the person is using behave. If that trade is wrong
for you, unset the tokens before `start`.

Two spellings matter, and both fail **silently** when wrong:

- `Edit(...)` rules cover every file-editing tool. `Write(...)` rules are not
  consulted by file permission checks at all.
- An absolute path needs a **doubled** slash — `Edit(//tmp/x/**)`.
  `Edit(/tmp/x/**)` matches nothing, denies nothing, and looks like a rule that
  works.

Editing is allowed in the workspace and nowhere else; the real repository and
the obvious secret stores are *denied*, which beats allow and beats an
interactive approval. Everything else falls through to a prompt — a boundary a
person can see. `$TMPDIR` is writable by spawned processes, because builds and
test runners are unusable without it.

Not under `~/.claude`: that tree is denied whole so a session cannot edit the
hooks watching it, which would make every workspace a subtree of its own deny
rule — and deny beats allow regardless of specificity. `start` refuses a
workspace inside any denied tree rather than opening a session that cannot edit
its own files.

`start` refuses to open a session it could not prove was confined. The probe
attempts both escapes, checks that an edit inside the workspace *succeeds*, and
reports on itself — so a probe that never ran fails closed rather than passing
for silence, and a policy that forbids what it should allow fails too. Set
`LASTLIGHT_WORK_VERIFY=off` to skip the proof and accept that risk deliberately.

### Landing does not make work pushable

`land` fast-forwards the branch into the real repository. Fast-forward only:
divergence is for a person to look at, not for a script to resolve by
overwriting one side.

It deliberately does **not** check for a review marker. A marker proving a
review is worth something only if the reviewed code could not have written it —
and everything in the workspace is under the session's control, including its
own git dir. So the proof lives where the sandbox cannot reach: markers are
written only by a review run in the real repository, and only a marker opens the
push gate. Landing moves code onto a branch; the gate still decides whether it
can leave.

The same argument applies to the signal that says *this is a workspace at all*.
It used to be a file in the clone's own git dir, which meant a session could
delete it, write a marker beside it, and push. Live workspaces are recorded in
`~/.lastlight/workspaces/` instead — one small file per workspace, holding the
workspace path and the repository it came from. That directory sits outside
`allowWrite`, so no spawned process can write it, and it is refused to the
`Edit` tool explicitly, because the two layers cover different things. It stays
*readable*, since the gate runs inside the session and has to tell a workspace
from an ordinary checkout; it holds paths, not secrets.

Entries are pruned when the workspace they name is gone, so nothing has to be
cleaned up by hand.

## What is and is not gated

The line is **new SHAs delivered to origin**. `docs/gate-contract.md` states
the purpose this follows from, ranks the ways it can fail, and records what is
deliberately out of scope; read that before changing any of the rules.

Gated until a marker exists for the SHA being pushed:

- every `git push` — including `-C`, `cd`/`pushd`, subshells, refspecs, force
  pushes, and `--all`/`--mirror` (which cannot be enumerated, so they are refused)
- creating or un-drafting a pull request: `gh pr create`, `gh pr ready`,
  `gh pr reopen`, and `gh api` POSTing to a `/pulls` collection
- the GitHub MCP write tools — see below

Allowed without a review, because no new commit reaches origin: ref deletions
(`--delete`, `:branch`), tag-only pushes, `--dry-run`, anything outside a git
repo.

**Reads are never blocked.** Not `gh api` reads of pull requests, not reads
whose endpoint is built from a variable. A read delivers no SHA and triggers no
review, so refusing one costs the willingness to leave the gate switched on and
buys nothing.

**Merging is not gated.** A merge delivers no new SHA to origin and triggers no
review of unreviewed work. Most of the `gh api` classification used to exist to
recognise merges; it is gone.

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

A heredoc that *writes* a script containing `git push` does not trip the gate:
the body is data, and the scan reads the words a shell would produce rather
than matching text line by line.

## Tests

```bash
for t in tests/*.test.sh; do bash "$t"; done
```

| suite | cases | covers |
|---|---|---|
| `lastlight-review-gate.test.sh` | 245 | what is gated, what is allowed through |
| `lastlight-review-record.test.sh` | 16 | the pass bar and the attestation binding |
| `lastlight-review-run.test.sh` | 103 | flag parsing, the prompt, the defaults, the tool allowlist, and what may cross back out of the sandbox |
| `lastlight-sandbox.test.sh` | 119 | review isolation, the containment verdict, and what the branch may not own |
| `lastlight-work-sandbox.test.sh` | 142 | work isolation, policy spelling, landing |

Counts are what each suite prints when you run it, not a count of lines that
look like assertions — several derive their cases from the credential list, so
the two differ and only the printed total tracks what actually ran.

The test repo deliberately has **no remote**, which proves the gate never
depended on the network.

The containment verdicts are tested as pure functions, without a model call —
deliberately, since a check that costs money per assertion is a check that stops
being run. The live end-to-end proof is run by hand when the policy changes, in
both directions: the full policy must verify, and a policy with a layer removed
must *not*.

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
