#!/usr/bin/env bash
# Selftest for dkms-version-guard.yml. Builds a scratch driver repo, replays
# the guard step over base/head pairs and asserts pass or fail per case.
set -uo pipefail

REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
WORKFLOW=$REPO_ROOT/.github/workflows/dkms-version-guard.yml

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

GUARD=$WORK/guard-step.sh

extract() {
	"$1" - "$WORKFLOW" "$GUARD" <<'PY'
import sys, yaml
workflow, out = sys.argv[1], sys.argv[2]
steps = yaml.safe_load(open(workflow))["jobs"]["packaged-content"]["steps"]
scripts = [s["run"] for s in steps if "run" in s]
assert len(scripts) == 1, f"expected one run step, found {len(scripts)}"
open(out, "w", newline="\n").write(scripts[0])
PY
}

for py in python3 python; do
	command -v "$py" > /dev/null 2>&1 || continue
	extract "$py" && break
done

# Without this every case would fail closed and the err cases would pass for
# the wrong reason, reporting a broken harness as a working guard.
[ -s "$GUARD" ] || {
	echo "::error::could not extract the guard step from $WORKFLOW" >&2
	exit 1
}

dkms_conf() {
	printf 'PACKAGE_NAME="imx585-jetson-dkms"\nPACKAGE_VERSION="%s"\nBUILT_MODULE_NAME[0]="nv_imx585"\n' "$1"
}

cd "$WORK"
git init -q repo
cd repo
git config user.email selftest@kurokesu.com
git config user.name selftest
# Fixtures are byte-exact on purpose, one case turns dkms.conf CRLF.
git config core.autocrlf false
mkdir -p scripts
dkms_conf 0.1.0 > dkms.conf
echo 'int probe(void) { return 0; }' > nv_imx585.c
echo 'sensor {};' > imx585.dts
echo 'obj-m += nv_imx585.o' > Makefile
echo 'depmod -a' > dkms.postinst
echo 'exit 0' > scripts/conftest.sh
echo '# imx585' > README.md
echo 'set -e' > setup.sh
git add -A
git commit -qm 'Fixture base'
BASE=$(git rev-parse HEAD)
# Guard resolves its base as merge-base of origin/<base ref> and HEAD.
git update-ref refs/remotes/origin/main "$BASE"

pass=0
fail=0

# case_run <name> <ok|err> <shell edits applied on top of base>
case_run() {
	local name=$1 expect=$2 edits=$3
	git checkout -q -B pr "$BASE"
	bash -c "$edits"
	git add -A
	git commit -qm "$name" --allow-empty
	local out rc got=ok
	out=$(BASE_REF=main bash "$GUARD" 2>&1) || rc=$?
	[ "${rc:-0}" -eq 0 ] || got=err
	if [ "$got" = "$expect" ]; then
		pass=$((pass + 1))
		printf '  PASS  %-42s (%s)\n' "$name" "$got"
	else
		fail=$((fail + 1))
		printf '  FAIL  %-42s expected %s got %s\n%s\n' "$name" "$expect" "$got" "$out"
	fi
}

echo '== packaged versus repo-only =='
case_run 'readme only, no bump'            ok  'echo more >> README.md'
case_run 'setup.sh only, no bump'          ok  'echo more >> setup.sh'
case_run 'source changed, no bump'         err 'echo "// fix" >> nv_imx585.c'
case_run 'dts changed, no bump'            err 'echo "// x" >> imx585.dts'
case_run 'makefile changed, no bump'       err 'echo "# x" >> Makefile'
case_run 'postinst changed, no bump'       err 'echo "# x" >> dkms.postinst'
case_run 'scripts changed, no bump'        err 'echo "# x" >> scripts/conftest.sh'
case_run 'header added, no bump'           err 'echo "#define X 1" > mode_tbls.h'
case_run 'packaged file deleted, no bump'  err 'rm imx585.dts'

echo '== bumps =='
case_run 'source changed, patch bump'      ok  'echo "// fix" >> nv_imx585.c; sed -i s/0.1.0/0.1.1/ dkms.conf'
case_run 'source changed, minor bump'      ok  'echo "// cap" >> nv_imx585.c; sed -i s/0.1.0/0.2.0/ dkms.conf'
case_run 'bump alone, no packaged change'  ok  'sed -i s/0.1.0/0.1.1/ dkms.conf'
case_run 'version went backwards'          err 'echo "// x" >> nv_imx585.c; sed -i s/0.1.0/0.0.9/ dkms.conf'
case_run 'crlf dkms.conf, patch bump'      ok  'echo "// x" >> nv_imx585.c; sed -i s/0.1.0/0.1.1/ dkms.conf; sed -i "s/$/\r/" dkms.conf'

echo '== base moved after fork point =='
# origin/main has bumped to 0.1.1 on its own. Judged against origin tip
# instead of the fork point, PR's matching bump would read as no bump.
git checkout -q -B mainline "$BASE"
echo '// mainline fix' >> nv_imx585.c
sed -i s/0.1.0/0.1.1/ dkms.conf
git add -A
git commit -qm 'Mainline bump'
git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
case_run 'PR bump matches moved base tip'  ok  'echo "// pr" >> nv_imx585.c; sed -i s/0.1.0/0.1.1/ dkms.conf'
git update-ref refs/remotes/origin/main "$BASE"

echo '== pre-release opens a series =='
case_run 'plain to pre-release'            ok  'echo "// x" >> nv_imx585.c; sed -i s/0.1.0/0.2.0-alpha.1/ dkms.conf'
case_run 'off-grammar pre-release, warns'  ok  'echo "// x" >> nv_imx585.c; sed -i s/0.1.0/0.2.0-wip/ dkms.conf'

echo '== mid-series, base is already a pre-release =='
git checkout -q -B series "$BASE"
echo '// series start' >> nv_imx585.c
sed -i s/0.1.0/0.2.0-alpha.1/ dkms.conf
git add -A
git commit -qm 'Fixture pre-release base'
BASE=$(git rev-parse HEAD)
git update-ref refs/remotes/origin/main "$BASE"
case_run 'later PR in series, no bump'     ok  'echo "// more" >> nv_imx585.c'
case_run 'alpha.1 to alpha.2'              ok  'echo "// x" >> nv_imx585.c; sed -i s/alpha.1/alpha.2/ dkms.conf'
case_run 'promote to plain release'        ok  'echo "// last" >> nv_imx585.c; sed -i s/0.2.0-alpha.1/0.2.0/ dkms.conf'
case_run 'series version went backwards'   err 'echo "// x" >> nv_imx585.c; sed -i s/0.2.0-alpha.1/0.1.5/ dkms.conf'

echo '== base predates dkms.conf =='
git checkout -q -B bare "$BASE"
git rm -q dkms.conf
git commit -qm 'Fixture without dkms.conf'
BASE=$(git rev-parse HEAD)
git update-ref refs/remotes/origin/main "$BASE"
case_run 'PR introduces dkms.conf'         ok  'printf %s\\n PACKAGE_VERSION=\"0.1.0\" > dkms.conf'

echo
if [ "$fail" -eq 0 ]; then
	echo "OK: $pass cases passed."
else
	echo "::error::$fail of $((pass + fail)) version guard cases failed."
fi
[ "$fail" -eq 0 ]
