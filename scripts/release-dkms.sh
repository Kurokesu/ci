#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Tag and push a paired release: v<upstream-version> on source branch,
# debian/<full-version> on packaging branch. Both names derive from
# debian/changelog at packaging tip. Pushing packaging tag triggers
# .github/workflows/release.yml.
# See "Releasing" in debian/source/README.source
#
# Usage: ./release.sh [--prepare | --execute]   (no args = dry run)
#   --prepare opens a debian/changelog entry versioned from dkms.conf
set -eu

REMOTE=origin
SRC_BRANCH=main
PKG_BRANCH=debian/latest
CI_WORKFLOW=ci.yml

print() { printf '  %-9s %s\n' "$1" "$2"; }
die() { printf '%s\n' "$@" >&2; exit 1; }
need() {
	command -v "$1" >/dev/null 2>&1 \
		|| die "ERROR: '$1' not found. Install it:" "sudo apt install $2"
}
dkms_ver() { git show "$1:dkms.conf" | sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p'; }

# dkms.conf carries semver (0.2.0-beta.1). Debian swaps pre-release
# hyphen for '~', which dpkg orders before release. Git refs cannot
# carry '~', so packaging tag uses '_' (DEP-14)
to_deb()    { printf '%s\n' "$1" | sed 's/-/~/g'; }
to_semver() { printf '%s\n' "$1" | sed 's/~/-/g'; }
to_ref()    { printf '%s\n' "$1" | sed 's/~/_/g'; }

# Tagging and pushing require an explicit --execute
MODE=dry-run
case "${1:-}" in
	--prepare) MODE=prepare ;;
	--execute) MODE=execute ;;
	--dry-run|'') MODE=dry-run ;;
	*) echo "usage: ./release.sh [--prepare | --execute]   (no args = dry run)" >&2; exit 2 ;;
esac

need dpkg-parsechangelog dpkg-dev
if [ "$MODE" = prepare ]; then
	need dch devscripts
else
	need curl curl
	need python3 python3
fi

if [ "$MODE" = prepare ]; then
	[ -f debian/changelog ] \
		|| die "ERROR: no debian/changelog here. Run from packaging worktree."
	git fetch --tags --quiet "$REMOTE" "$SRC_BRANCH" "$PKG_BRANCH"
	# dch edits this checkout, so refuse a base origin moved past
	git merge-base --is-ancestor "${REMOTE}/${PKG_BRANCH}" HEAD \
		|| die "ERROR: checkout is behind ${REMOTE}/${PKG_BRANCH}. Pull first."
	DKMS_VER=$(dkms_ver "${REMOTE}/${SRC_BRANCH}")
	[ -n "$DKMS_VER" ] \
		|| die "ERROR: no PACKAGE_VERSION in dkms.conf on ${REMOTE}/${SRC_BRANCH}."
	# Only grammar where dpkg and semver ordering agree
	printf '%s' "$DKMS_VER" | grep -Eq '^[0-9]+(\.[0-9]+)*(-(alpha|beta|rc)\.[0-9]+)?$' \
		|| die "ERROR: dkms.conf version '${DKMS_VER}' is not X.Y.Z or X.Y.Z-(alpha|beta|rc).N."
	DKMS_VER=$(to_deb "$DKMS_VER")
	CUR=$(dpkg-parsechangelog -SVersion)
	TAG_VER=${CUR#*:}
	CUR_UPSTREAM=${TAG_VER%-*}
	# No packaging tag means top entry is still unreleased
	if ! git rev-parse -q --verify "refs/tags/debian/$(to_ref "$TAG_VER")" >/dev/null; then
		if [ "$DKMS_VER" = "$CUR_UPSTREAM" ]; then
			echo "Entry ${CUR} already prepared and unreleased, nothing to do."
			echo "Edit it, commit, push, then run ./release.sh."
			exit 0
		fi
		die "ERROR: top entry ${CUR} is unreleased, but dkms.conf on ${SRC_BRANCH} says ${DKMS_VER}." \
			"       Release ${CUR} first, or fix mismatch by hand."
	fi
	# Same upstream means a packaging-only rebuild, so bump the revision.
	# EDIT ME blocks release until a real entry replaces it
	if [ "$DKMS_VER" = "$CUR_UPSTREAM" ]; then
		NEW="${DKMS_VER}-$(( ${CUR##*-} + 1 ))"
		MSG="Packaging update. EDIT ME: describe the rebuild reason."
	else
		NEW="${DKMS_VER}-1"
		MSG="New upstream release. EDIT ME: describe the changes."
	fi
	dpkg --compare-versions "$NEW" gt "$CUR" \
		|| die "ERROR: computed ${NEW} does not advance ${CUR}." \
			"       Bump dkms.conf on ${SRC_BRANCH} first."
	# dch takes attribution from DEBEMAIL, a "Name <email>" value fills
	# both fields
	[ -n "${DEBEMAIL:-}" ] \
		|| die "ERROR: DEBEMAIL is unset, changelog entry needs an author." \
			"       export DEBEMAIL='Your Name <you@kurokesu.com>' and rerun."
	export DEBEMAIL
	dch --newversion "$NEW" --distribution unstable \
		--force-distribution "$MSG"
	echo "Opened ${NEW} in debian/changelog with an EDIT ME placeholder."
	echo "Describe release, commit, push, then rerun ./release.sh once CI is green."
	echo "EDIT ME blocks release until replaced."
	exit 0
fi

git fetch --tags --quiet "$REMOTE"

# Read from the remote packaging tip, not the working tree. A tag must
# name the version of the commit it points at
CHANGELOG=$(git show "${REMOTE}/${PKG_BRANCH}:debian/changelog")
PKG=$(printf '%s\n' "$CHANGELOG" | dpkg-parsechangelog -l- -SSource)
FULL=$(printf '%s\n' "$CHANGELOG" | dpkg-parsechangelog -l- -SVersion)
# Colons are illegal in git refs, so strip any epoch
TAG_VER=${FULL#*:}
UPSTREAM=${TAG_VER%-*}
# Same grammar --prepare enforces, in changelog form. Catches a
# hand-edited entry
printf '%s' "$UPSTREAM" | grep -Eq '^[0-9]+(\.[0-9]+)*(~(alpha|beta|rc)\.[0-9]+)?$' \
	|| die "ERROR: changelog version '${UPSTREAM}' is not X.Y.Z or X.Y.Z~(alpha|beta|rc).N."
# Top entry seeds the release notes, so no placeholder may reach them
if printf '%s\n' "$CHANGELOG" | sed -n '2,/^ -- /p' | grep -q 'EDIT ME'; then
	die "ERROR: top changelog entry still carries EDIT ME placeholder." \
		"       Describe release, commit, push, then rerun ./release.sh."
fi

SRC_TAG="v$(to_semver "$UPSTREAM")"
PKG_TAG="debian/$(to_ref "$TAG_VER")"
PKG_SHA=$(git rev-parse "${REMOTE}/${PKG_BRANCH}")

# Reuse the source tag across packaging-only rebuilds (-2, -3)
CREATE_SRC=1
if SRC_SHA=$(git rev-parse -q --verify "refs/tags/${SRC_TAG}^{commit}"); then
	CREATE_SRC=0
	SRC_NOTE="existing tag, reused"
else
	SRC_SHA=$(git rev-parse "${REMOTE}/${SRC_BRANCH}")
	SRC_NOTE="new tag on ${REMOTE}/${SRC_BRANCH}"
fi

# Catch version drift before any tags exist
DKMS_VER=$(to_deb "$(dkms_ver "$SRC_SHA")")
[ "$DKMS_VER" = "$UPSTREAM" ] \
	|| die "ERROR: dkms.conf at ${SRC_SHA} maps to '${DKMS_VER}'," \
		"       but debian/changelog says '${UPSTREAM}'." \
		"       Bump dkms.conf on ${SRC_BRANCH} to match."

# Refuse a version already tagged at another commit
if EXISTING=$(git rev-parse -q --verify "refs/tags/${PKG_TAG}^{commit}"); then
	[ "$EXISTING" = "$PKG_SHA" ] \
		|| die "ERROR: ${PKG_TAG} exists at ${EXISTING}," \
			"       but ${REMOTE}/${PKG_BRANCH} is at ${PKG_SHA}." \
			"       Bump changelog revision for a new release."
fi

REPO=$(git remote get-url "$REMOTE" \
	| sed -E 's#(git@|https://)github\.com[:/]##; s#\.git$##')

print RELEASE "${FULL}"
print SOURCE "${SRC_TAG} -> ${SRC_SHA} (${SRC_NOTE})"
print PACKAGING "${PKG_TAG} -> ${PKG_SHA} (${REMOTE}/${PKG_BRANCH})"

# Block unless the packaging tip is CI-green. An unreachable API blocks
# too, fail closed
BRANCH_ENC=$(printf %s "$PKG_BRANCH" | sed 's#/#%2F#g')
RUNS=$(curl -sf --max-time 10 \
	"https://api.github.com/repos/${REPO}/actions/workflows/${CI_WORKFLOW}/runs?branch=${BRANCH_ENC}&per_page=1") \
	|| die "ERROR: cannot reach GitHub API for ${REPO} run status."
CI=$(printf '%s\n' "$RUNS" | python3 -c 'import json,sys
r = json.load(sys.stdin)["workflow_runs"]
print(((r[0]["conclusion"] or "in_progress") + " " + r[0]["head_sha"]) if r else "none -")' \
	2>/dev/null) || die "ERROR: unexpected run list from GitHub API."
CONCLUSION=${CI% *}
CI_SHA=${CI#* }
case "$CONCLUSION" in
	success) ;;
	none)
		die "ERROR: no ${CI_WORKFLOW} run found for ${PKG_BRANCH}." \
			"       Push ${PKG_BRANCH} and wait for CI."
		;;
	*)
		die "ERROR: latest ${CI_WORKFLOW} run on ${PKG_BRANCH} is '${CONCLUSION}', not 'success'." \
			"       Wait for a green run on packaging tip."
		;;
esac
# A green run for some other commit is stale, not proof for this tip
[ "$CI_SHA" = "$PKG_SHA" ] \
	|| die "ERROR: green run covers ${CI_SHA}," \
		"       not packaging tip ${PKG_SHA}. Wait for a run on it."

if [ "$MODE" = dry-run ]; then
	echo "Dry run, no tags created, nothing pushed."
	echo "Rerun with --execute to create and push tags."
	exit 0
fi

printf "Proceed? [y/N] "
read -r ANSWER
case "$ANSWER" in
	y|Y) ;;
	*) echo "Aborted."; exit 1 ;;
esac

if [ "$CREATE_SRC" -eq 1 ]; then
	git tag -a "$SRC_TAG" "$SRC_SHA" -m "${PKG} $(to_semver "$UPSTREAM")"
fi
git rev-parse -q --verify "refs/tags/${PKG_TAG}" >/dev/null \
	|| git tag -a "$PKG_TAG" "$PKG_SHA" -m "${PKG} Debian release ${FULL}"

# release.yml fires on packaging tag, so source tag lands with it
git push --atomic "$REMOTE" "refs/tags/${SRC_TAG}" "refs/tags/${PKG_TAG}"
echo "Pushed. Watch release at: https://github.com/${REPO}/actions"
