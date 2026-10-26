#!/usr/bin/env bash
#
# Repackages Docker's RockyLinux 8 SBX RPM as a tarball that can be extracted
# without root or a package manager. The tarball is the RPM payload exactly as
# the RPM lays it out (usr/, etc/), under one top-level directory, and nothing
# else: no scripts, no bundled dependencies. sbx finds its libexec/ files
# relative to its own binary, so it runs from wherever it is extracted.
#
# Why the Rocky 8 RPM and not Docker's generic linux tarball: the RPM's shim and
# mkfs binaries carry the older glibc/kernel ABI tag that RHEL 8 family hosts
# (AlmaLinux 8.10) need.
#
# The host still has to provide what the RPM declares with Requires (glibc,
# libgcc, ca-certificates, dbus-daemon, gnome-keyring); on a stock AlmaLinux 8
# that is already enough for `sbx login` without a keyring (verified).
#
# Host requirements: docker only (the work runs in a rockylinux:8 container).
#
# Usage:
#   ./scripts/build-sbx-tarball-from-rpm.sh
#   RELEASE_TAG=v0.50.0 ARCH=amd64 ./scripts/build-sbx-tarball-from-rpm.sh
#
# Output:
#   dist/<release tag>/DockerSandboxes-linux-<arch>-rockylinux8.tar.gz
#   dist/<release tag>/DockerSandboxes-linux-<arch>-rockylinux8.tar.gz.sha256

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RELEASE_TAG="${RELEASE_TAG:-v0.50.0}"
ARCH="${ARCH:-amd64}"                       # amd64 | arm64 (Docker's naming)
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/dist/$RELEASE_TAG}"   # one folder per release: file names carry no version
ROCKY_IMAGE="${ROCKY_IMAGE:-rockylinux:8}"

case "$ARCH" in
  amd64|arm64) ;;
  *) echo "ERROR: ARCH must be amd64 or arm64 (got '$ARCH')" >&2; exit 1 ;;
esac

RPM_NAME="DockerSandboxes-linux-${ARCH}-rockylinux8.rpm"
RPM_URL="https://github.com/docker/sbx-releases/releases/download/${RELEASE_TAG}/${RPM_NAME}"
TARBALL_NAME="DockerSandboxes-linux-${ARCH}-rockylinux8.tar.gz"

# ---------------------------------------------------------------- host side --
if [ "${1:-}" != "--in-container" ]; then
  command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found on PATH (the build runs in a $ROCKY_IMAGE container)." >&2; exit 1; }
  mkdir -p "$OUT_DIR"
  echo "==> Building $TARBALL_NAME ($RELEASE_TAG) in $ROCKY_IMAGE"
  docker run --rm \
    -e RELEASE_TAG="$RELEASE_TAG" -e ARCH="$ARCH" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$SCRIPT_DIR":/scripts:ro \
    -v "$OUT_DIR":/dist \
    "$ROCKY_IMAGE" bash /scripts/build-sbx-tarball-from-rpm.sh --in-container
  cat <<EOT

==> Done.
    $OUT_DIR/$TARBALL_NAME
    $OUT_DIR/$TARBALL_NAME.sha256

On the target AlmaLinux 8.x host (no sudo, no network):
    sha256sum -c $TARBALL_NAME.sha256
    mkdir -p ~/.docker/sbx && tar -xzf $TARBALL_NAME -C ~/.docker/sbx --strip-components=1
    export PATH="\$HOME/.docker/sbx/usr/bin:\$PATH"
    sbx login
EOT
  exit 0
fi

# ----------------------------------------------------------- container side --
WORK=/work
PAYLOAD="$WORK/docker-sbx"
mkdir -p "$PAYLOAD"

echo "==> Installing build tools"
dnf -y -q install cpio >/dev/null

echo "==> Downloading $RPM_NAME"
curl -sfL --retry 3 -o "$WORK/$RPM_NAME" "$RPM_URL" \
  || { echo "ERROR: could not download $RPM_URL (does $RELEASE_TAG have a $ARCH RPM?)" >&2; exit 1; }
echo "    source rpm sha256: $(sha256sum "$WORK/$RPM_NAME" | cut -d' ' -f1)"
rpm -qp --qf '    %{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' "$WORK/$RPM_NAME" 2>/dev/null

echo "==> Extracting the RPM payload"
(cd "$PAYLOAD" && rpm2cpio "$WORK/$RPM_NAME" | cpio -idm --quiet)

# Fail rather than ship something that is not a usable sbx install.
for must in usr/bin/sbx usr/libexec/containerd-shim-nerdbox-v1 usr/libexec/mkfs.erofs usr/libexec/lib/libsailor.so; do
  [ -f "$PAYLOAD/$must" ] || { echo "ERROR: $must missing from the RPM payload" >&2; exit 1; }
done
ls "$PAYLOAD"/usr/libexec/nerdbox-kernel-* "$PAYLOAD"/usr/libexec/nerdbox-rootfs-*.erofs >/dev/null

echo "==> Packing $TARBALL_NAME"
# Normalised ownership (extracting as non-root must not try to chown). File
# modes are the RPM's own, including the setuid bit on the GPU shim; a non-root
# extract does not apply it, a root extract gives the same result as the RPM.
tar --owner=0 --group=0 --numeric-owner --sort=name -C "$WORK" -czf "/dist/$TARBALL_NAME" docker-sbx
(cd /dist && sha256sum "$TARBALL_NAME" > "$TARBALL_NAME.sha256")
chown "$HOST_UID:$HOST_GID" "/dist/$TARBALL_NAME" "/dist/$TARBALL_NAME.sha256" 2>/dev/null || true
ls -lh "/dist/$TARBALL_NAME"
