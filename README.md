# Docker Sandboxes tarballs for RHEL 8 / AlmaLinux 8

Tarball builds of [Docker Sandboxes](https://github.com/docker/sbx-releases/releases) (`sbx`).

**Why this exists:** Docker ships `sbx` for RHEL-family Linux as an RPM, which needs root and a
package manager. Some environments have neither. These tarballs are the RPM's contents,
unmodified, so `sbx` can be extracted into a home directory without root.

**Download:** [github.com/john-craft/sbx-releases/releases](https://github.com/john-craft/sbx-releases/releases).
Release tags match Docker's (e.g. `v0.50.0`); each has `amd64` and `arm64` tarballs with `.sha256`
files and install steps in the notes.

**What's inside:** only what Docker's RPM installs, nothing added. See
[`scripts/build-sbx-tarball-from-rpm.sh`](scripts/build-sbx-tarball-from-rpm.sh), which downloads
Docker's RPM from the releases page above, extracts it with `rpm2cpio`, and packs it with `tar`.
You can compare `tar -tzf <tarball>` with `rpm -qlp <rpm>`.
