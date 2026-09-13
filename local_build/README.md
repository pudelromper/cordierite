# Building Cordierite without GitHub Actions

Everything the GitHub workflows do can run on one Linux box. The scripts in
this directory mirror `.github/workflows/build.yml` and `build_iso.yml` step
for step, so both paths produce the same images from the same `Containerfile`
and `installer/` tree.

| Script | What it does | Runs as |
| --- | --- | --- |
| `build-images.sh [image...]` | build with buildah, rechunk with `rpm-ostree compose build-chunked-oci`, run the goss smoke tests, push, retag, cosign-sign | root or rootless podman user |
| `build-iso.sh [image...]` | build the live-ISO payload from `installer/`, run titanoboa, checksum, sign the ISO, optionally upload with rclone | root |
| `release.sh` | `build-images.sh` then (if `CORDIERITE_BUILD_ISO=1`) `build-iso.sh`; what the systemd timer runs | root |
| `sync-upstream.sh` | fetch and merge `ublue-os/bazzite` main, list conflicts | you |

`just release-images`, `just release-isos` and `just sync-upstream` wrap them.

## Build box requirements

- Fedora (or anything with recent podman) with: `podman buildah skopeo jq git cosign`,
  plus `rclone` for ISO uploads and `goss`/`dgoss` for the smoke tests.
  `rpm-ostree` is not needed on the host; rechunking runs inside the image.
- Roughly 100 GB free under `CORDIERITE_STATE_DIR` and the container storage.
  Each image is ~10 GB, rechunking needs that again, and the DNF cache mounts
  stay warm between runs on a persistent box.
- Network access to `ghcr.io` (base and akmods images), the coprs, Terra,
  Flathub and GitHub releases.
- Root for the ISO step. titanoboa mounts the payload image with
  `--mount type=image`, which needs it in root's container storage.

## One-time setup

1. Clone the repo where the units expect it:
   `git clone https://github.com/pudelromper/cordierite /opt/cordierite`
   (or adjust `WorkingDirectory`/`ExecStart` in the units).
2. Configuration:
   `install -d -m 0750 /etc/cordierite && cp local_build/build.env.example /etc/cordierite/build.env`
   then edit registry, vendor and paths.
3. Signing key. Either copy the existing private key that pairs with the
   repository's `cosign.pub` to `/etc/cordierite/cosign.key`, or generate a new
   pair with `cosign generate-key-pair` and commit the new `cosign.pub`. The
   public key is baked into the image (`build_files/install-signing`), so
   clients verify updates against whichever key was current when they built.
   Put the key password in `/etc/cordierite/cosign.password` (mode 0600) and
   set `COSIGN_PASSWORD_FILE`.
4. Registry login, once, as the user that runs the pipeline:
   `podman login ghcr.io` (a token with `write:packages`) or your own registry.
   With `REGISTRY_AUTH_FILE` set in `build.env` the credentials can live under
   `/etc/cordierite` instead of the user's home.
5. Optional: `rclone config` for the B2 bucket and set `RCLONE_REMOTE`, e.g.
   `b2:cordierite-releases/releases`, which reproduces the
   `releases/<track>/<iso>` layout the GitHub workflow used.
6. Units:
   ```
   cp local_build/systemd/cordierite-release.{service,timer} /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now cordierite-release.timer
   ```
   The timer fires Monday 04:40 local time, the same slot the GitHub schedule
   used. `systemctl start cordierite-release.service` runs it now;
   `journalctl -u cordierite-release -f` follows it.

First run: set `CORDIERITE_NO_PUSH=1` and run `local_build/build-images.sh
cordierite` by hand. It builds and rechunks one image and leaves it in local
storage as `localhost/cordierite-chunked-cordierite` without touching the
registry. Boot-test it with `podman run --rm -it <that image> bash` or by
rebasing a VM to `ostree-unverified-image:containers-storage:...`.

## Versioning and tags

Identical to the workflow. Each run gets `FEDORA.YYYYMMDD` (prefixed with
`testing-`/`unstable-` on those tracks), with `.1`, `.2` appended if the tag
already exists in the registry for any image. Alias tags on the stable track
are `latest`, `stable`, `stable-<fedora>` and `stable-<version>`. The Fedora
release and kernel pins are read from the matrix in `build.yml`, so bumping
them there updates both paths; `build.env` can override.

## Registry choices

- **GHCR, private.** Keep `CORDIERITE_REGISTRY=ghcr.io`. Every client then
  needs a read token in `/etc/ostree/auth.json` (`{"auths":{"ghcr.io":{"auth":"<base64 user:token>"}}}`)
  for `bootc`/`rpm-ostree` updates, and in `~/.config/containers/auth.json`
  for `skopeo`-based tooling such as the rollback helper.
- **Self-hosted over Netbird.** Run zot or the plain `registry` image on a
  host reachable through the Netbird network, set `CORDIERITE_REGISTRY` to
  it, and the network is the access control: no tokens on clients. The image
  reference baked into `/usr/share/ublue-os/image-info.json` and the signature
  policy follow `CORDIERITE_REGISTRY`, so images built this way update from
  the private registry. Two upstream tools still assume `ghcr.io`:
  `bazzite-rollback-helper` (`brh`) and the `ujust verify-image` recipe. Both
  are optional conveniences; updates themselves go through `bootc` and are
  unaffected.

Switching registries later means rebuilding once (the reference is inside the
image) and rebasing existing installs to the new reference.

## Signature verification

`build_files/install-signing` adds a `sigstoreSigned` entry for
`<registry>/<vendor>` to `/etc/containers/policy.json` and installs
`cosign.pub` as `/etc/pki/containers/cordierite.pub`. Before this, the base
image's policy only verified `ghcr.io/ublue-os` and accepted everything else
unverified, so the `ostree-image-signed:` reference was cosmetic. Now an
unsigned or wrongly signed image is refused at update time, which means the
key in `COSIGN_KEY` must match the `cosign.pub` the running image was built
with. Rotate keys by building once with the new public key while still
signing with the old private key, then switching.

## Keeping up with upstream

`just sync-upstream` fetches `ublue-os/bazzite` main and merges it. Clean
merges happen most weeks; the Containerfile, the two build workflows,
`build_files/image-info`, `installer/`, `yafti.yml`, the MOTD templates and
the KDE preset specs are where Cordierite's intent lives and where conflicts
land. After resolving, `just just-check` validates the just files, and
`CORDIERITE_NO_PUSH=1 local_build/build-images.sh cordierite` is the cheapest
proof the merge builds.

## Retiring the GitHub workflows

Nothing here depends on them. To stop them without deleting: remove the
`schedule` and `push` triggers from `.github/workflows/build.yml` and keep
`workflow_dispatch` as a manual fallback. Delete `.github/pull.yml` once
`sync-upstream.sh` has replaced the pull bot.
