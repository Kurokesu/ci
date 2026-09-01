#!/usr/bin/env bash
# Selftest for scripts/release-dkms.sh. Builds a scratch driver repo with a
# packaging branch, stubs curl and dch, then asserts each guard fires.
# Prepare cases stop at the dch call, entry formatting is dch's business.
set -uo pipefail

REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
SCRIPT=$REPO_ROOT/scripts/release-dkms.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

OUT=$WORK/out
BIN=$WORK/bin
MIN=$WORK/minbin
REPO=$WORK/repo
export STUB_RUNS_BODY=$WORK/runs.json
export STUB_STATUS_BODY=$WORK/statuses.json
export STUB_DCH_ARGS=$WORK/dch.args
mkdir -p "$BIN" "$MIN"
# No case may depend on operator environment
unset DEBEMAIL DEBFULLNAME

# Stubs keep every case off the network. curl serves a canned body per
# endpoint, dch only records its arguments
cat > "$BIN/curl" <<'SH'
#!/bin/sh
case "$*" in
*/statuses*)
	[ "${STUB_STATUS_RC:-0}" -eq 0 ] || exit "$STUB_STATUS_RC"
	cat "$STUB_STATUS_BODY" ;;
*/actions/workflows/*)
	[ "${STUB_RUNS_RC:-0}" -eq 0 ] || exit "$STUB_RUNS_RC"
	cat "$STUB_RUNS_BODY" ;;
*)
	echo "stub curl: unexpected call: $*" >&2
	exit 99 ;;
esac
SH
cat > "$BIN/dch" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$STUB_DCH_ARGS"
SH
chmod +x "$BIN/curl" "$BIN/dch"

# Preflight runs before any tool call, so a stub is enough to look present
for t in dpkg-parsechangelog curl python3 dch; do
	printf '#!/bin/sh\nexit 0\n' > "$MIN/$t"
	chmod +x "$MIN/$t"
done

dkms_conf() {
	printf 'PACKAGE_NAME="sel-rpi-dkms"\nPACKAGE_VERSION="%s"\nBUILT_MODULE_NAME[0]="sel"\n' "$1"
}

changelog() { # <version> <bullet>
	printf 'sel-rpi-dkms (%s) unstable; urgency=medium\n\n  * %s\n\n -- selftest <selftest@kurokesu.com>  Mon, 31 Aug 2026 10:00:00 +0300\n' \
		"$1" "$2"
}

git init -q --bare "$WORK/origin.git"
git init -q -b src "$REPO"
cd "$REPO"
git config user.email selftest@kurokesu.com
git config user.name selftest
git remote add origin "$WORK/origin.git"

# Three source states, so cases can move the source branch under a
# changelog without touching the packaging worktree
echo 'int probe(void) { return 0; }' > sel.c
dkms_conf 0.1.0 > dkms.conf
git add -A
git commit -qm 'Fixture source 0.1.0'
git branch -q src-010
dkms_conf 0.2.0 > dkms.conf
git commit -qam 'Fixture source 0.2.0'
git branch -q src-020
dkms_conf 0.3.0 > dkms.conf
git commit -qam 'Fixture source 0.3.0'
git branch -q src-030

git checkout -q --orphan pkg
git rm -q -rf .
mkdir debian
changelog 0.1.0-1 'Initial release.' > debian/changelog
git add -A
git commit -qm 'Fixture packaging 0.1.0-1'

pass=0
fail=0
RUN_PATH=$BIN:$PATH
RUN_CWD=$REPO
RC=0

run() {
	RC=0
	( cd "$RUN_CWD" && PATH="$RUN_PATH" /bin/sh "$SCRIPT" "$@" ) > "$OUT" 2>&1 || RC=$?
}

check() { # check <name> <want-exit> <want-text>
	if [ "$RC" = "$2" ] && grep -qF -- "$3" "$OUT"; then
		pass=$((pass + 1))
		printf '  PASS  %-44s\n' "$1"
	else
		fail=$((fail + 1))
		printf '  FAIL  %-44s exit %s want %s, no match for %s\n' "$1" "$RC" "$2" "$3"
		sed 's/^/          /' "$OUT"
	fi
}

check_file() { # check_file <name> <file> <want-text>
	if grep -qF -- "$3" "$2"; then
		pass=$((pass + 1))
		printf '  PASS  %-44s\n' "$1"
	else
		fail=$((fail + 1))
		printf '  FAIL  %-44s no match for %s\n' "$1" "$3"
		sed 's/^/          /' "$2"
	fi
}

runs_json() { # <conclusion, empty for null> <head sha>
	local c=null
	[ -z "$1" ] || c="\"$1\""
	printf '{"workflow_runs":[{"conclusion":%s,"head_sha":"%s"}]}\n' "$c" "$2" \
		> "$STUB_RUNS_BODY"
}

status_json() { # <state, or none>
	if [ "$1" = none ]; then
		echo '[]' > "$STUB_STATUS_BODY"
	else
		printf '[{"context":"packaging/source-build","state":"%s"}]\n' "$1" \
			> "$STUB_STATUS_BODY"
	fi
}

pkg_push() { # <commit message>, leaves the CI stub green for the new tip
	git commit -qam "$1"
	git push -qf origin HEAD:refs/heads/debian/latest
	git fetch -q origin
	PKG_SHA=$(git rev-parse origin/debian/latest)
	runs_json success "$PKG_SHA"
}

src_push() { # <local source branch>
	git push -qf origin "$1:refs/heads/main"
	git fetch -q origin
	SRC_SHA=$(git rev-parse origin/main)
}

git push -q origin HEAD:refs/heads/debian/latest
src_push src-010
git fetch -q origin
PKG_SHA=$(git rev-parse origin/debian/latest)

echo '== preflight =='
pre_case() { # <name> <tool> <package> [script arg]
	rm -f "$MIN/$2"
	RUN_PATH=$MIN
	run ${4:+"$4"}
	RUN_PATH=$BIN:$PATH
	check "$1" 1 "sudo apt install $3"
	printf '#!/bin/sh\nexit 0\n' > "$MIN/$2"
	chmod +x "$MIN/$2"
}
pre_case 'dch missing names devscripts'   dch                 devscripts --prepare
pre_case 'curl missing names curl'        curl                curl
pre_case 'python3 missing names python3'  python3             python3
pre_case 'parsechangelog names dpkg-dev'  dpkg-parsechangelog dpkg-dev

echo '== packaging CI gate =='
status_json success
runs_json success "$PKG_SHA"
run
check 'green run and status pass' 0 'Dry run, no tags created'
check 'summary block aligns' 0 'PACKAGING debian/0.1.0-1'
export STUB_RUNS_RC=7; run; unset STUB_RUNS_RC
check 'unreachable run API blocks' 1 'cannot reach GitHub API'
echo 'not json' > "$STUB_RUNS_BODY"; run
check 'malformed run list blocks' 1 'unexpected run list'
echo '{"workflow_runs":[]}' > "$STUB_RUNS_BODY"; run
check 'no run at all blocks' 1 'no ci.yml run found'
runs_json failure "$PKG_SHA"; run
check 'red run blocks' 1 "run on debian/latest is 'failure'"
runs_json '' "$PKG_SHA"; run
check 'unfinished run blocks' 1 "run on debian/latest is 'in_progress'"
runs_json success deadbeef; run
check 'run for another commit blocks' 1 'green run covers deadbeef'

echo '== source commit status =='
runs_json success "$PKG_SHA"
status_json none; run
check 'missing status blocks a new tag' 1 "no packaging/source-build status on ${SRC_SHA}"
status_json failure; run
check 'failed status blocks' 1 "status on ${SRC_SHA} is 'failure'"
export STUB_STATUS_RC=7; run; unset STUB_STATUS_RC
check 'unreachable status API blocks' 1 "cannot reach GitHub API for ${SRC_SHA}"
echo 'not json' > "$STUB_STATUS_BODY"; run
check 'malformed status list blocks' 1 'unexpected status list'
# A reused source tag was proven at its own release
git tag -a v0.1.0 -m fixture "$SRC_SHA"
status_json none; run
check 'reused tag needs no status' 0 'existing tag, reused'
git tag -d v0.1.0 > /dev/null
status_json success

echo '== changelog and version =='
changelog 0.1.0-1 'New upstream release. EDIT ME: describe the changes.' > debian/changelog
pkg_push 'Placeholder entry'
run
check 'EDIT ME placeholder blocks' 1 'carries EDIT ME placeholder'
changelog '0.1.0~wip-1' 'Off grammar.' > debian/changelog
pkg_push 'Off-grammar version'
run
check 'off-grammar version blocks' 1 'is not X.Y.Z'
changelog 0.2.0-1 'Next release.' > debian/changelog
pkg_push 'Changelog ahead of source'
run
check 'version drift blocks' 1 "maps to '0.1.0'"
src_push src-020
git tag -a debian/0.2.0-1 -m fixture "$SRC_SHA"
run
check 'packaging tag elsewhere blocks' 1 'Bump changelog revision'

echo '== prepare =='
RUN_CWD=$WORK
run --prepare
RUN_CWD=$REPO
check 'prepare outside a worktree blocks' 1 'no debian/changelog here'
run --prepare
check 'prepare without DEBEMAIL blocks' 1 'DEBEMAIL is unset'
export DEBEMAIL='selftest <selftest@kurokesu.com>'
run --prepare
check 'same upstream bumps the revision' 0 'Opened 0.2.0-2'
check_file 'dch called with that version' "$STUB_DCH_ARGS" '--newversion 0.2.0-2'
check_file 'dch vendor pinned to Debian' "$STUB_DCH_ARGS" '--vendor Debian'
src_push src-030
run --prepare
check 'new upstream opens revision 1' 0 'Opened 0.3.0-1'
unset DEBEMAIL

echo
if [ "$fail" -eq 0 ]; then
	echo "OK: $pass cases passed."
else
	echo "::error::$fail of $((pass + fail)) release cases failed."
fi
[ "$fail" -eq 0 ]
