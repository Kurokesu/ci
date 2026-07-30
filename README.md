# Kurokesu CI

[![Selftest](https://github.com/Kurokesu/ci/actions/workflows/selftest.yml/badge.svg)](https://github.com/Kurokesu/ci/actions/workflows/selftest.yml)

Shared CI for Kurokesu repos: reusable GitHub Actions workflows, canonical release scripts and archive public keyring. Callers reference workflows here with thin shims at `@main`, so fixes land once and propagate without caller commits.

## Workflows

| Workflow | Purpose | Called from |
| --- | --- | --- |
| `kernel-code-style.yml` | clang-format plus kernel checkpatch, profile per `platform` input | driver repo `main` shim |
| `dkms-build.yml` | DKMS source package plus arch:all `.deb` in a clean container, callers pass nothing repo-specific | packaging branch `ci.yml` shim |
| `dkms-release.yml` | release pipeline on `debian/*` tag push: verify tags, build, sign, publish | packaging branch `release.yml` shim |
| `deb-sign.yml` | bundle artifacts, sign `SHA256SUMS` with archive key, self-verify | `dkms-release.yml` |
| `deb-publish.yml` | GitHub pre-release from `release-assets` artifact, re-run refreshes assets | `dkms-release.yml` |

`selftest.yml` is this repo's own CI. It runs `dkms-build.yml` against dummy DKMS fixtures on `selftest/*` orphan branches, one plain-version pair and one semver pre-release pair. Sign and publish have no selftest.

## Kernel code style

Two jobs: clang-format against caller's `.clang-format` and mainline `checkpatch.pl` with zero findings tolerated. checkpatch enforces Linux kernel coding style, hence the `kernel-` prefix, userspace projects should not call this. `platform` input picks the checkpatch profile. `rpi` runs `--strict`, these drivers hold the mainline bar. `jetson` drops `--strict` and ignores `TRACING_LOGGING`, NVIDIA's tegracam reference is the standard for modules that build against nvidia-oot and cannot go upstream. Full rationale in the workflow header.

Caller shim, `code-style.yml` on `main`:

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
jobs:
  code-style:
    uses: Kurokesu/ci/.github/workflows/kernel-code-style.yml@main
    with:
      platform: rpi
```

## DKMS release family

`dkms-build.yml` and `dkms-release.yml` assume DEP-14 layout in the calling repo: driver source on `main` tagged `v<upstream>`, packaging recipe on `debian/latest` tagged `debian/<upstream>-<revision>`. Package name and build dependencies come from the recipe. Release verifies paired tags against `debian/changelog`, then builds, signs and publishes a GitHub pre-release. Signing needs the org-level `ARCHIVE_GPG_SIGNING_KEY` secret, passed with `secrets: inherit`.

`release.yml` on the packaging branch:

```yaml
on:
  push:
    tags: ['debian/**']
permissions:
  contents: write
jobs:
  release:
    uses: Kurokesu/ci/.github/workflows/dkms-release.yml@main
    secrets: inherit
```

`ci.yml` on the packaging branch:

```yaml
on:
  push:
    branches: [debian/latest]
  pull_request:
    branches: [debian/latest]
permissions:
  contents: read
jobs:
  build:
    uses: Kurokesu/ci/.github/workflows/dkms-build.yml@main
    with:
      upstream-ref: main
```

Shims live on the packaging branch, not `main`, because GitHub Actions resolves `pull_request` and tag-push triggers from a base branch's own workflow files.

### Release scripts

Canonical scripts in `scripts/` are family-suffixed (`release-<family>.sh`). Callers carry no copy, only a thin `release.sh` launcher that resolves the shims' ref to a commit SHA, prints it for the audit trail and fetches the canonical script at that SHA. Maintainer tooling and CI stay on one protocol version.

```bash
./release.sh --prepare   # open a changelog entry from dkms.conf on main
./release.sh             # dry run, validate tags and CI state
./release.sh --execute   # tag and push atomically
```

`dkms.conf` on the calling repo's `main` is the one place a human bumps a version. Script derives everything else from `debian/changelog` and refuses on version drift, red CI, retag attempts or an unedited `EDIT ME` changelog entry.

## Versioning

`dkms.conf` carries the version in semver form. Plain `X.Y.Z` passes through every layer unchanged. Pre-releases change spelling per layer, because Debian spells pre-release with `~` and git refs cannot carry `~` at all:

| Layer | Form | Example |
| --- | --- | --- |
| `dkms.conf` and the DKMS tree in `/usr/src` | semver | `0.2.0-beta.1` |
| `debian/changelog` and `.deb` metadata | `-` becomes `~` | `0.2.0~beta.1-1` |
| Source tag | `v` plus semver | `v0.2.0-beta.1` |
| Packaging tag | `~` becomes `_` (DEP-14) | `debian/0.2.0_beta.1-1` |
| Release asset tarball | `~` becomes `_` (GitHub forbids `~` in asset names) | `<package>_0.2.0_beta.1-1.tar.gz` |

Pre-release grammar is machine-enforced as `(alpha|beta|rc).N`, the range where dpkg and semver ordering agree. `release.sh --prepare` checks it before opening a changelog entry and the release preflight checks it on every tag. apt archive refuses `~` versions into its stable suites.

## Keys

`keys/kurokesu-archive-keyring.gpg` is the public keyring for the archive signing key. `deb-sign.yml` uses it for a signature self-check after signing. Verify a downloaded release the same way:

```bash
gpgv --keyring kurokesu-archive-keyring.gpg SHA256SUMS.asc SHA256SUMS
```
