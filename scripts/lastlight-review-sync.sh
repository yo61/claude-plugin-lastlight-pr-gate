#!/usr/bin/env bash
# Pull Last Light's PR-review assets from npm into a local staging dir, so a
# review can be run here (on the Claude Code subscription) instead of on the
# Last Light server (which bills per head SHA).
#
# WHY npm AND NOT THE OBVIOUS ROUTES
#   `lastlight skills install`  ships the OPERATOR skills (lastlight-server,
#                               lastlight-debug, ...). It does NOT ship
#                               pr-review -- that is an internal sandbox skill.
#   `lastlight fork pr-review`  does ship it, but needs `--home <checkout>`;
#                               locked decision 12 moved the assets out of the
#                               CLI package, so it couples you to a git clone.
#   npm lastlight-core          ships `skills/` and `workflows/` in its `files`
#                               array. Version-pinned, no checkout, no server.
#                               Verified byte-identical to the checkout at
#                               0.28.1 (skill version 7.4.0).
#
# SKILLS ARE CONFIGURATION DATA, NOT CODE.
#   A deployment can override any skill, prompt or workflow through the overlay
#   mechanism (`lastlight fork`, the `lastlight-overlay` skill). So npm is the
#   STOCK baseline, correct only while no override is in play -- it is NOT
#   authoritative about what reviews a given PR. The only authoritative source
#   is the running instance: `--deployed <url> <token>` diffs the staged tree
#   against `GET /admin/skills/:name` and fails if they disagree.
#
#   Robin does not override today (2026-09-04), which is why the npm baseline is
#   sound right now. Run `--deployed` before trusting a local review the moment
#   that changes. Note the admin API serves SKILL.md and prompts, but NOT skill
#   sub-files such as references/findings-schema.md -- an overlay that edits a
#   reference file cannot be detected this way.
#
# The staged tree is deliberately PRISTINE -- an unmodified copy, so it can be
# diffed against a future release to see exactly what changed in the review.
#
# Usage:
#   lastlight-review-sync.sh [version]     # default: latest
#   lastlight-review-sync.sh --check       # verify staged tree matches npm
#   lastlight-review-sync.sh --deployed URL TOKEN
#                                          # compare staged vs a running server
set -euo pipefail

readonly PKG=lastlight-core
readonly STAGE="${LASTLIGHT_REVIEW_DIR:-$HOME/.claude/lastlight-review}"
readonly ASSETS=(
  skills/pr-review/SKILL.md
  skills/pr-review/references/findings-schema.md
  skills/code-review/SKILL.md
  workflows/pr-review.yaml
  workflows/prompts/review.md
  workflows/prompts/reviewer.md
  workflows/prompts/review-falsify.md
  workflows/prompts/review-adjudicate.md
)

die() {
  printf 'lastlight-review-sync: %s\n' "$1" >&2
  exit 1
}

# Pack the package into $1 and print the extracted `package/` root.
fetch() {
  local version=$1 dest=$2 tarball
  local -a candidates
  command -v npm > /dev/null 2>&1 || die "npm not found"
  (cd "$dest" && npm pack "${PKG}@${version}" > /dev/null 2>&1) \
    || die "could not fetch ${PKG}@${version} from npm"
  # Glob rather than parsing `ls` (SC2012); nullglob keeps an unmatched
  # pattern from surviving as a literal filename.
  shopt -s nullglob
  candidates=("$dest"/"${PKG}"-*.tgz)
  shopt -u nullglob
  tarball=${candidates[0]-}
  [[ -f $tarball ]] || die "npm pack produced no tarball"
  tar -xzf "$tarball" -C "$dest"
  printf '%s/package' "$dest"
}

resolve_version() {
  npm view "${PKG}@${1:-latest}" version 2> /dev/null | tr -d "'\" " \
    || die "could not resolve ${PKG}@${1:-latest}"
}

sync() {
  local want=${1:-latest} version tmp root missing=0
  version=$(resolve_version "$want")
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064  # expand $tmp now, not at trap time
  trap "rm -rf '$tmp'" EXIT
  root=$(fetch "$version" "$tmp")

  for rel in "${ASSETS[@]}"; do
    if [[ ! -f "$root/$rel" ]]; then
      printf '  MISSING from package: %s\n' "$rel" >&2
      missing=1
      continue
    fi
    mkdir -p "$STAGE/$(dirname "$rel")"
    cp "$root/$rel" "$STAGE/$rel"
  done
  [[ $missing -eq 0 ]] || die "package layout changed -- update ASSETS in this script"

  printf '%s\n' "$version" > "$STAGE/.version"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STAGE/.synced-at"

  printf 'Synced %s@%s -> %s\n' "$PKG" "$version" "$STAGE"
  printf '  pr-review skill version: %s\n' \
    "$(sed -n 's/^version: //p' "$STAGE/skills/pr-review/SKILL.md" | head -1)"
  printf '  %d assets\n' "${#ASSETS[@]}"
}

check() {
  local staged tmp root version drift=0
  [[ -f "$STAGE/.version" ]] || die "nothing staged yet -- run without --check first"
  staged=$(cat "$STAGE/.version")
  version=$(resolve_version latest)
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  if [[ $staged != "$version" ]]; then
    printf 'Staged %s, npm latest is %s.\n' "$staged" "$version"
  fi
  root=$(fetch "$staged" "$tmp")
  for rel in "${ASSETS[@]}"; do
    if ! diff -q "$STAGE/$rel" "$root/$rel" > /dev/null 2>&1; then
      printf '  LOCALLY MODIFIED: %s\n' "$rel"
      drift=1
    fi
  done
  if [[ $drift -eq 0 ]]; then
    printf 'Staged tree matches %s@%s exactly.\n' "$PKG" "$staged"
  else
    die "staged tree has been edited -- re-sync to restore fidelity"
  fi
}

# The only source that reflects overlay customisation on the live instance.
compare_deployed() {
  local url=$1 token=$2 remote local_file drift=0
  for skill in pr-review code-review; do
    local_file="$STAGE/skills/$skill/SKILL.md"
    [[ -f $local_file ]] || die "not staged: $skill"
    remote=$(curl -fsSL -H "Authorization: Bearer ${token}" \
      "${url%/}/admin/skills/${skill}" 2> /dev/null) \
      || die "could not read ${url%/}/admin/skills/${skill}"
    if diff -q <(printf '%s' "$remote") <(cat "$local_file") > /dev/null 2>&1; then
      printf '  same as deployed: %s\n' "$skill"
    else
      printf '  DIFFERS from deployed: %s\n' "$skill"
      drift=1
    fi
  done
  [[ $drift -eq 0 ]] || die "the running instance is not reviewing with the staged skill"
}

case "${1:-}" in
  --check) check ;;
  --deployed)
    [[ $# -eq 3 ]] || die "usage: --deployed <server-url> <admin-token>"
    compare_deployed "$2" "$3"
    ;;
  --help | -h) sed -n '2,30p' "$0" ;;
  *) sync "${1:-latest}" ;;
esac
