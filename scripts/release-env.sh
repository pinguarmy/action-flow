#!/bin/bash
# Derives release variables for .github/workflows/release.yml and prints KEY=VALUE lines on stdout
# (the workflow appends them to $GITHUB_ENV and $GITHUB_OUTPUT). Nothing is written or changed.
# Inputs (env): RELEASE_EVENT (push, workflow_dispatch, ...), RELEASE_REF_TYPE (tag or branch),
#   RELEASE_REF_NAME (tag or branch name), RELEASE_RUN_NUMBER (positive integer, dry runs only).
# A tag push of vX.Y.Z or vX.Y.Z-label is a release; every other run is a dry run (0.1.0, -ci.<run>).
# Any other tag shape fails before anything is built.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVENT="${RELEASE_EVENT:-}"
REF_TYPE="${RELEASE_REF_TYPE:-}"
REF_NAME="${RELEASE_REF_NAME:-}"
RUN="${RELEASE_RUN_NUMBER:-}"
die() { printf 'release-env: %s\n' "$1" >&2; exit 2; }
SUFFIX_RE='-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*'
TAG_RE="^v([0-9]+\\.[0-9]+\\.[0-9]+)($SUFFIX_RE)?\$"
if [[ "$EVENT" == push && "$REF_TYPE" == tag ]]; then
 MODE=release
 TAG="$REF_NAME"
 [[ "$TAG" =~ $TAG_RE ]] || die "tag '$TAG' must look like v1.2.3 or v1.2.3-label (letters, digits, dots and hyphens in the label)"
 VERSION="${BASH_REMATCH[1]}"
 SUFFIX="${BASH_REMATCH[2]}"
 if [[ -z "$SUFFIX" ]]; then FINAL=1; else FINAL=0; fi
else
 MODE=dry-run
 TAG=""
 [[ "$RUN" =~ ^[1-9][0-9]*$ ]] || die 'RELEASE_RUN_NUMBER must be a positive integer for dry runs'
 VERSION=0.1.0
 SUFFIX="-ci.$RUN"
 FINAL=0
fi
# The build number is the commit count, which is only correct with full history.
[[ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" == false ]] || die 'shallow clone: check out with fetch-depth: 0'
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || die "invalid build number '$BUILD'"
printf 'RELEASE_MODE=%s\n' "$MODE"
printf 'RELEASE_TAG=%s\n' "$TAG"
printf 'APP_VERSION=%s\n' "$VERSION"
printf 'RELEASE_SUFFIX=%s\n' "$SUFFIX"
printf 'RELEASE_FINAL=%s\n' "$FINAL"
printf 'APP_BUILD=%s\n' "$BUILD"
printf 'RELEASE_NAME=ActionFlow-%s%s\n' "$VERSION" "$SUFFIX"
printf 'RELEASE_CLI=actionflow-cli-%s%s\n' "$VERSION" "$SUFFIX"
