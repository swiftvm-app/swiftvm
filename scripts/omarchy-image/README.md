# Omarchy ARM image

The built-in Omarchy setup starts from an image built with
`../build-omarchy-image.sh`. It uses Omarchy's signed ARM edge packages and
first-boot hardware provisioning, not a SwiftVM fork of the desktop. The
builder is adapted from Try Omarchy; see `LICENSE.try-omarchy` and the source
revision at the top of the builder.

## Build

Run only in a **disposable Arch Linux ARM guest**, as root. The builder changes
its package databases, keyrings and pacman hooks, and mounts loop devices.
Allow at least 8 GiB of memory and 60 GiB of free disk space. No host shares,
SSH keys or release credentials are needed in the guest.

```sh
pacman -Syu --noconfirm --needed archlinuxarm-keyring arch-install-scripts \
  btrfs-progs dosfstools e2fsprogs jq python qemu-img zstd curl
mkdir -p /var/lib/swiftvm-image/{output,work}
bash scripts/build-omarchy-image.sh \
  --output /var/lib/swiftvm-image/output \
  --work /var/lib/swiftvm-image/work
```

Transfer the builder and this directory together. Use absolute output and work
paths, on disk rather than a memory-backed `/tmp`. A work directory is for one
build at a time; starting another removes failed build state there but retains
the package download cache. Use a new output directory for each candidate.

The output contains a compressed QCOW2 for local verification, 1 GiB download
pieces, `image.json`, package inventories, repository/version provenance, and
`SHA256SUMS`. Accounts, passwords, host keys, machine ID, random seed and the
pacman master key are not shared by machines. SwiftVM's seed supplies the user
and guest tools; the first boot creates each machine's identities.

## Refresh and publication

The image is an installation snapshot. Installed machines update directly from
Omarchy, so a new image is not needed for every upstream release. Refresh it
periodically to reduce update downloads and when a first-boot or integration
fix requires one. The edge channel is rolling: repository hashes and package
versions record what was built, not a promise that a later build is identical.

### Monthly automation

`Build Omarchy ARM Image` runs on the **1st of each month at 04:23 UTC** and
supports **Run workflow** on the default branch. GitHub can delay scheduled
runs, and the workflow must be on the default branch for the schedule to work.
It bootstraps a signature-verified Arch Linux ARM rootfs on a disposable Ubuntu
ARM runner and invokes the same builder. The runner needs at least 35 GiB free;
unused preinstalled SDKs are removed before the space check.

The build job has read-only repository permissions and no stored checkout
credentials. A separate publication job uploads the pieces, versioned manifest,
checksums, package inventory, and source provenance to a **draft** image release.
Only after every uploaded asset's size and SHA-256 match the build does it
publish the prerelease, always with `--latest=false`. Failed builds or uploads
leave the previous published image current. A rerun may repair a draft but
never overwrites a published image's assets.

CI verifies package signatures, QCOW2 integrity, and download checksums. It
**does not boot a guest**. Validate the first Actions-built image manually in
SwiftVM, and repeat that check when changing the builder or first-boot contract:
use a separate `SWIFTVM_HOME`, then check first-boot completion, login, graphics,
disk growth, package trust, and a reboot. Automatic monthly publication does
not guarantee that future upstream edge packages are free of regressions.

### Catalog discovery and compatibility

The app queries GitHub's releases API for the newest published `omarchy-image-`
release containing `omarchy-arm64-edge-v1.json`. It skips drafts, unrelated app
releases, and images with only a newer incompatible manifest. It searches up to
20 pages of 100 releases, not GitHub's overall latest release, which is reserved
for the app. No catalog edit or app release is needed for a compatible refresh.

The manifest is `{ "format": 1, "image": ... }`, wrapping `image.json`. Its asset
name promises compatibility with v1 first-boot provisioning on ARM edge. If a
builder change breaks that contract, publish a new manifest version and update
the app's selector; do not mark the incompatible image as v1.

Resolution pins one release's content-addressed URLs, piece sizes, and SHA-256
checksums for the entire creation. It checks the manifest against GitHub's
asset digest, then the downloader checks every piece and the assembled image.
Metadata is bounded and re-fetched for each creation. On a connection failure,
server error, or rate limit, a previously resolved image may be reused only if
its completed download is cached. Invalid metadata is an error, not a reason
to silently select an older image. Existing machines keep updating upstream.

For a manual image publication, use the tag from `provenance.json`, include the
versioned manifest with the pieces and metadata, and use a draft until uploads
are complete and verified. Never make an image the latest app release.
Publishing an image does not publish a new SwiftVM app.
