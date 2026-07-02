# Kurokesu CI

[![Selftest](https://github.com/Kurokesu/ci/actions/workflows/selftest.yml/badge.svg)](https://github.com/Kurokesu/ci/actions/workflows/selftest.yml)

Shared release plumbing for Kurokesu repos: reusable GitHub Actions workflows, canonical release scripts and the archive public keyring.

Workflows group by release family. The `dkms-*` pair serves DKMS driver packaging repos. `deb-sign.yml` and `deb-publish.yml` are family-agnostic building blocks for any `.deb` release pipeline. Callers reference the workflows here with thin shims at `@main`.

## DKMS workflows

Both assume a DEP-14 layout in the calling repo: driver source on `main`, tagged `v<upstream>` per release, and packaging recipe on `debian/latest`, tagged `debian/<upstream>-<revision>`.

### dkms-build.yml

Builds a DKMS source package plus its arch:all `.deb` in a clean container. Package name comes from the recipe's `debian/changelog` `Source:` field and build dependencies come from `debian/control` via `apt-get build-dep`, so callers pass nothing repo-specific.

Inputs:

| Input | Required | Default | Purpose |
| --- | --- | --- | --- |
| `upstream-ref` | yes | | Ref of driver source to build (branch or tag) |
| `source-repo` | no | caller repo | owner/repo of driver source |
| `recipe-repo` | no | caller repo | owner/repo of packaging recipe |
| `recipe-ref` | no | caller SHA | Ref of recipe checkout |
| `container-image` | no | `debian:trixie` | Image the package is built in |

Outputs: `package`, `packaging-version` and `artifact` (name of the uploaded artifact carrying the `.deb`, `.dsc`, `.orig.tar.gz`, `.changes`, `.buildinfo` and `.debian.tar.xz`).

### dkms-release.yml

Full release pipeline on a `debian/<full-version>` tag push. Verifies the paired `v<upstream>` source tag exists and the tag matches `debian/changelog`, then builds, signs and publishes a GitHub pre-release with notes seeded from the top changelog entry. Requires the `ARCHIVE_GPG_SIGNING_KEY` secret (org-level, pass with `secrets: inherit`).

### Caller shims

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

## Shared workflows

### deb-sign.yml

Bundles build artifacts into per-artifact tarballs, writes `SHA256SUMS`, signs it with the archive key and verifies the signature against `keys/kurokesu-archive-keyring.gpg` from this repo. Uploads the result as the `release-assets` artifact.

### deb-publish.yml

Creates a pre-release on the caller's repo from the `release-assets` artifact. A re-run refreshes assets and leaves title, notes and the Pre-release flag intact. Inputs: `tag` (release tag, also the title) and `notes` (initial notes for a new release).

## Selftest

`selftest.yml` is this repo's own CI. It calls `dkms-build.yml` against the dummy DKMS fixtures on the `selftest/*` orphan branches, each pair arranged like a caller's `main` and `debian/latest`: a plain version on `selftest/upstream` + `selftest/recipe` and a semver pre-release on the `selftest/*-pre` pair. Both artifact sets are asserted. Sign and publish have no selftest.

## Release scripts

Canonical names in `scripts/` are family-suffixed (`release-<family>.sh`) so sibling families can sit beside each other. Callers carry no copy. The packaging branch root has a thin `release.sh` launcher that resolves the same ref as the workflow shims to a commit SHA, prints it for the audit trail, fetches the canonical script at that SHA and runs it with the caller's arguments. Fetching at the shims' ref keeps maintainer tooling and CI on one protocol version, and script fixes propagate without caller commits.

`scripts/release-dkms.sh` cuts a paired-tag DKMS release. Operator commands:

```bash
./release.sh --prepare   # open a changelog entry from dkms.conf on main
./release.sh             # dry run, validate tags and CI state
./release.sh --execute   # tag and push atomically
```

`dkms.conf` on the calling repo's `main` is the one place a human bumps a version. The script derives everything else from `debian/changelog` and refuses on version drift, red CI or retag attempts.

## Versioning

`dkms.conf` carries the version in semver form. Plain `X.Y.Z` versions pass through every layer unchanged. Semver pre-releases change spelling per layer, because Debian spells pre-release with `~` and git refs cannot carry `~` at all:

| Layer | Form | Example |
| --- | --- | --- |
| `dkms.conf` and the DKMS tree in `/usr/src` | semver | `0.2.0-beta.1` |
| `debian/changelog` and `.deb` metadata | `-` becomes `~` | `0.2.0~beta.1-1` |
| Source tag | `v` plus semver | `v0.2.0-beta.1` |
| Packaging tag | `~` becomes `_` (DEP-14) | `debian/0.2.0_beta.1-1` |
| Release asset tarball | `~` becomes `_` (GitHub forbids `~` in asset names) | `<package>_0.2.0_beta.1-1.tar.gz` |

The pre-release grammar is machine-enforced as `(alpha|beta|rc).N`, the range where dpkg and semver ordering agree. `release-dkms.sh --prepare` checks it before opening a changelog entry and the `dkms-release.yml` preflight checks it on every tag. A future apt publish job must refuse `~` versions into the stable suite.

## Keys

`keys/kurokesu-archive-keyring.gpg` is the public keyring for the archive signing key. `deb-sign.yml` uses it for a signature self-check after signing. Verify a downloaded release the same way:

```bash
gpgv --keyring kurokesu-archive-keyring.gpg SHA256SUMS.asc SHA256SUMS
```
