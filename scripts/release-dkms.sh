#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Tag and push a paired release: v<upstream-version> on the source
# branch, debian/<full-version> on the packaging branch. Both tag
# names derive from debian/changelog on the packaging branch tip.
# The packaging-tag push triggers .github/workflows/release.yml.
# See "Releasing" in debian/source/README.source.
#
# Usage: ./release.sh [--prepare | --execute]   (no args = dry run)
#   --prepare opens a debian/changelog entry versioned from dkms.conf
#   on the source branch, the one place a human bumps the version.
set -eu

REMOTE=origin
SRC_BRANCH=main
PKG_BRANCH=debian/latest

# Default to a dry run. Tagging and pushing require an explicit --execute.
MODE=dry-run
case "${1:-}" in
	--prepare) MODE=prepare ;;
	--execute) MODE=execute ;;
	--dry-run|'') MODE=dry-run ;;
	*) echo "usage: ./release.sh [--prepare | --execute]   (no args = dry run)" >&2; exit 2 ;;
esac

# Version forms. dkms.conf carries semver (0.2.0-beta.1). Debian
# metadata swaps the pre-release hyphen for '~' (0.2.0~beta.1), which
# dpkg orders before the release. Tag names cannot carry '~': the
# source tag restores semver, the packaging tag uses '_' (DEP-14).
to_deb()    { printf '%s\n' "$1" | sed 's/-/~/g'; }
to_semver() { printf '%s\n' "$1" | sed 's/~/-/g'; }
to_ref()    { printf '%s\n' "$1" | sed 's/~/_/g'; }

if [ "$MODE" = prepare ]; then
	[ -f debian/changelog ] || {
		echo "ERROR: no debian/changelog here. Run from the packaging worktree." >&2
		exit 1
	}
	git fetch --tags --quiet "$REMOTE" "$SRC_BRANCH" "$PKG_BRANCH"
	# dch edits this checkout, so refuse a base the remote moved past.
	git merge-base --is-ancestor "${REMOTE}/${PKG_BRANCH}" HEAD || {
		echo "ERROR: checkout is behind ${REMOTE}/${PKG_BRANCH}. Pull first." >&2
		exit 1
	}
	DKMS_VER=$(git show "${REMOTE}/${SRC_BRANCH}:dkms.conf" \
		| sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p')
	[ -n "$DKMS_VER" ] || {
		echo "ERROR: no PACKAGE_VERSION in dkms.conf on ${REMOTE}/${SRC_BRANCH}." >&2
		exit 1
	}
	# Only the grammar where dpkg and semver ordering agree.
	printf '%s' "$DKMS_VER" | grep -Eq '^[0-9]+(\.[0-9]+)*(-(alpha|beta|rc)\.[0-9]+)?$' || {
		echo "ERROR: dkms.conf version '${DKMS_VER}' is not X.Y.Z or X.Y.Z-(alpha|beta|rc).N." >&2
		exit 1
	}
	DKMS_VER=$(to_deb "$DKMS_VER")
	CUR=$(dpkg-parsechangelog -SVersion)
	TAG_VER=${CUR#*:}
	CUR_UPSTREAM=${TAG_VER%-*}
	# The packaging tag marks the top entry released. No tag means the
	# entry is still pending, so never open another one on top of it.
	if ! git rev-parse -q --verify "refs/tags/debian/$(to_ref "$TAG_VER")" >/dev/null; then
		if [ "$DKMS_VER" = "$CUR_UPSTREAM" ]; then
			echo "Entry ${CUR} already prepared and unreleased - nothing to do."
			echo "Edit it, commit, push, then run ./release.sh."
			exit 0
		fi
		echo "ERROR: top entry ${CUR} is unreleased, but dkms.conf on ${SRC_BRANCH} says ${DKMS_VER}." >&2
		echo "       Release ${CUR} first, or fix the mismatch by hand." >&2
		exit 1
	fi
	# Same upstream means a packaging-only rebuild, so bump the revision.
	# EDIT ME blocks the release until the operator writes a real entry.
	if [ "$DKMS_VER" = "$CUR_UPSTREAM" ]; then
		NEW="${DKMS_VER}-$(( ${CUR##*-} + 1 ))"
		MSG="Packaging update. EDIT ME: describe the rebuild reason."
	else
		NEW="${DKMS_VER}-1"
		MSG="New upstream release. EDIT ME: describe the changes."
	fi
	dpkg --compare-versions "$NEW" gt "$CUR" || {
		echo "ERROR: computed ${NEW} does not advance ${CUR}." >&2
		echo "       Bump dkms.conf on ${SRC_BRANCH} first." >&2
		exit 1
	}
	# dch takes attribution from DEBEMAIL. A "Name <email>" value fills
	# both fields. Refusing beats guessing a wrong author into a
	# released changelog.
	[ -n "${DEBEMAIL:-}" ] || {
		echo "ERROR: DEBEMAIL is unset, the changelog entry needs an author." >&2
		echo "       export DEBEMAIL='Your Name <you@kurokesu.com>' and rerun." >&2
		exit 1
	}
	export DEBEMAIL
	dch --newversion "$NEW" --distribution unstable \
		--force-distribution "$MSG"
	echo "Opened ${NEW} in debian/changelog with an EDIT ME placeholder."
	echo "Describe the release, commit, push, then rerun ./release.sh once CI is green."
	echo "The release stays blocked while EDIT ME remains in the entry."
	exit 0
fi

git fetch --tags --quiet "$REMOTE"

# Read the changelog from the remote packaging tip, not the working
# tree. The tag must name the version of the commit it points at.
CHANGELOG=$(git show "${REMOTE}/${PKG_BRANCH}:debian/changelog")
PKG=$(printf '%s\n' "$CHANGELOG" | dpkg-parsechangelog -l- -SSource)
FULL=$(printf '%s\n' "$CHANGELOG" | dpkg-parsechangelog -l- -SVersion)
# Strip any epoch. Colons are illegal in git refs, so no tag carries one.
TAG_VER=${FULL#*:}
UPSTREAM=${TAG_VER%-*}
# Same grammar --prepare enforces, in changelog form. A hand-edited
# entry fails here, not as pushed tags the preflight then rejects.
printf '%s' "$UPSTREAM" | grep -Eq '^[0-9]+(\.[0-9]+)*(~(alpha|beta|rc)\.[0-9]+)?$' || {
	echo "ERROR: changelog version '${UPSTREAM}' is not X.Y.Z or X.Y.Z~(alpha|beta|rc).N." >&2
	exit 1
}
# The top entry seeds the release notes. Block the --prepare
# placeholder from ever reaching them.
if printf '%s\n' "$CHANGELOG" | sed -n '2,/^ -- /p' | grep -q 'EDIT ME'; then
	echo "ERROR: top changelog entry still carries the EDIT ME placeholder." >&2
	echo "       Describe the release, commit, push, then rerun ./release.sh." >&2
	exit 1
fi
SRC_TAG="v$(to_semver "$UPSTREAM")"
PKG_TAG="debian/$(to_ref "$TAG_VER")"
PKG_SHA=$(git rev-parse "${REMOTE}/${PKG_BRANCH}")

# Reuse the source tag across packaging-only rebuilds (-2, -3). Keep an
# existing tag's target, otherwise tag the source tip.
CREATE_SRC=1
if SRC_SHA=$(git rev-parse -q --verify "refs/tags/${SRC_TAG}^{commit}"); then
	CREATE_SRC=0
	SRC_NOTE="existing tag, reused"
else
	SRC_SHA=$(git rev-parse "${REMOTE}/${SRC_BRANCH}")
	SRC_NOTE="new tag on ${REMOTE}/${SRC_BRANCH}"
fi

# Catch version drift before any tags exist. The build guard in
# debian/rules would fail too, but only mid-release. Compare in
# Debian form, the changelog's native one.
DKMS_VER=$(git show "${SRC_SHA}:dkms.conf" \
	| sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p')
DKMS_VER=$(to_deb "$DKMS_VER")
if [ "$DKMS_VER" != "$UPSTREAM" ]; then
	echo "ERROR: dkms.conf at ${SRC_SHA} maps to '${DKMS_VER}'," >&2
	echo "       but debian/changelog says '${UPSTREAM}'." >&2
	echo "       Bump dkms.conf on ${SRC_BRANCH} to match." >&2
	exit 1
fi

# A pre-existing packaging tag pointing elsewhere means the release
# was already cut from a different commit. Never silently retag.
if EXISTING=$(git rev-parse -q --verify "refs/tags/${PKG_TAG}^{commit}"); then
	if [ "$EXISTING" != "$PKG_SHA" ]; then
		echo "ERROR: ${PKG_TAG} exists at ${EXISTING}," >&2
		echo "       but ${REMOTE}/${PKG_BRANCH} is at ${PKG_SHA}." >&2
		echo "       Bump the changelog revision for a new release." >&2
		exit 1
	fi
fi

REPO=$(git remote get-url "$REMOTE" \
	| sed -E 's#(git@|https://)github\.com[:/]##; s#\.git$##')

echo "Release:       ${FULL}"
echo "Source tag:    ${SRC_TAG} -> ${SRC_SHA} (${SRC_NOTE})"
echo "Packaging tag: ${PKG_TAG} -> ${PKG_SHA} (${REMOTE}/${PKG_BRANCH})"

# Block unless the packaging tip is CI-green. An unreachable API blocks
# too. Releasing blind is as risky as releasing red.
BRANCH_ENC=$(printf %s "$PKG_BRANCH" | sed 's#/#%2F#g')
CI=$(curl -sf --max-time 10 \
	"https://api.github.com/repos/${REPO}/actions/runs?branch=${BRANCH_ENC}&per_page=1" \
	2>/dev/null \
	| python3 -c 'import json,sys
r = json.load(sys.stdin)["workflow_runs"]
print(((r[0]["conclusion"] or "in_progress") + " " + r[0]["head_sha"]) if r else "none -")' \
	2>/dev/null) || CI="unknown -"
CONCLUSION=${CI% *}
CI_SHA=${CI#* }
if [ "$CONCLUSION" != "success" ]; then
	echo "ERROR: latest CI on ${PKG_BRANCH} is '${CONCLUSION}', not 'success'." >&2
	echo "       Wait for a green run on the packaging tip." >&2
	exit 1
fi
# A green run for some other commit is stale, not proof for this tip.
if [ "$CI_SHA" != "$PKG_SHA" ]; then
	echo "ERROR: that run is for ${CI_SHA}," >&2
	echo "       not the packaging tip ${PKG_SHA}. Wait for CI on the tip." >&2
	exit 1
fi

if [ "$MODE" = dry-run ]; then
	echo "Dry run - no tags created, nothing pushed."
	echo "Re-run with --execute to create and push the tags."
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

# Atomic: both refs land or neither does, so release.yml's preflight
# can never fire without its paired source tag.
git push --atomic "$REMOTE" "refs/tags/${SRC_TAG}" "refs/tags/${PKG_TAG}"
echo "Pushed. Watch the release at: https://github.com/${REPO}/actions"
