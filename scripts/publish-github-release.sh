#!/usr/bin/env bash
#
# Publishes the tarballs in dist/<tag>/ as a GitHub release: creates the release (and
# its tag), uploads each tarball and its .sha256, then publishes it. Talks to the
# GitHub REST API directly with curl and jq; the gh CLI is not required.
#
# The release is created as a draft, the assets are uploaded and checked against
# the local files, and only then is it published, so nobody ever sees a release
# that is missing a file. The tag is created by GitHub when the release is
# published, on the default branch unless TARGET is set, so push first.
#
# Auth: a token with write access to the repo's contents (classic: `repo`;
# fine-grained: "Contents: read and write") in GITHUB_TOKEN or GH_TOKEN. If
# neither is set and `gh` is logged in, its token is used.
#
# Usage:
#   ./scripts/publish-github-release.sh                  # v0.50.0, amd64 + arm64
#   ./scripts/publish-github-release.sh --dry-run        # checks + notes, no API calls
#   ./scripts/publish-github-release.sh --replace        # re-upload into an existing release
#   RELEASE_TAG=v0.49.1 DIST_DIR=dist ARCHS=amd64 ./scripts/publish-github-release.sh
#
# Flags:
#   --dry-run   verify the local files and print what would happen; no network
#   --replace   the release for this tag already exists: replace same-named
#               assets instead of refusing
#   --draft     leave the release as a draft after uploading
#
# Env: RELEASE_TAG (v0.49.1), ARCHS ("amd64 arm64"), DIST_DIR (./dist/<tag>),
#      REPO (owner/name; default: parsed from `git remote origin`),
#      TARGET (branch or commit the tag is created on; default: repo default branch).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RELEASE_TAG="${RELEASE_TAG:-v0.50.0}"
ARCHS="${ARCHS:-amd64 arm64}"
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist/$RELEASE_TAG}"
TARGET="${TARGET:-}"
API="${GITHUB_API_URL:-https://api.github.com}"
UPLOADS="${GITHUB_UPLOADS_URL:-https://uploads.github.com}"

DRY_RUN=0 REPLACE=0 KEEP_DRAFT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --replace) REPLACE=1 ;;
    --draft)   KEEP_DRAFT=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument '$arg' (see --help)" >&2; exit 1 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done

[[ "$RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "RELEASE_TAG '$RELEASE_TAG' has characters that are not safe in a tag/URL"

# ------------------------------------------------------------------- repo --
if [ -z "${REPO:-}" ]; then
  origin="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
  REPO="$(printf '%s' "${origin%.git}" | sed -nE 's#^(https://([^@/]+@)?|ssh://git@|git@)github\.com[:/]([^/]+/[^/]+)$#\3#p')"
  [ -n "$REPO" ] || die "could not work out owner/name from the origin remote ('$origin'); set REPO=owner/name"
fi

# ----------------------------------------------------------------- assets --
ASSETS=()
for arch in $ARCHS; do
  tarball="DockerSandboxes-linux-${arch}-rockylinux8.tar.gz"
  for f in "$tarball" "$tarball.sha256"; do
    [ -f "$DIST_DIR/$f" ] || die "$DIST_DIR/$f not found (build it with ARCH=$arch ./scripts/build-sbx-tarball-from-rpm.sh, or limit ARCHS)"
    ASSETS+=("$f")
  done
done

sha256_check() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$1"; else shasum -a 256 -c "$1"; fi
}

echo "==> Checking local files against their .sha256"
for f in "${ASSETS[@]}"; do
  case "$f" in *.sha256) (cd "$DIST_DIR" && sha256_check "$f" >/dev/null) || die "$f does not match its tarball; rebuild" ;; esac
done

# -------------------------------------------------------------- the notes --
PRERELEASE=false
[[ "$RELEASE_TAG" == *-* ]] && PRERELEASE=true      # v0.49.0-rc3 and the like

release_notes() {
  local arch tarball
  cat <<EOT
Docker Sandboxes (\`sbx\`) ${RELEASE_TAG} for AlmaLinux / RHEL 8, repackaged as a tarball that needs no root and no package manager.

The tarball is the contents of Docker's own \`DockerSandboxes-linux-<arch>-rockylinux8.rpm\` from [docker/sbx-releases](https://github.com/docker/sbx-releases/releases/tag/${RELEASE_TAG}), unchanged, under one top-level \`docker-sbx/\` directory. Nothing is added. See the upstream release notes (linked above) for any security guidance before upgrading.

### Install

\`\`\`bash
sha256sum -c DockerSandboxes-linux-amd64-rockylinux8.tar.gz.sha256
mkdir -p ~/.docker/sbx && tar -xzf DockerSandboxes-linux-amd64-rockylinux8.tar.gz -C ~/.docker/sbx --strip-components=1
export PATH="\$HOME/.docker/sbx/usr/bin:\$PATH"     # add to ~/.bashrc
sbx login
\`\`\`

Use the \`arm64\` file on aarch64 hosts. The host needs \`/dev/kvm\` access, as with the RPM.

### SHA-256

\`\`\`
EOT
  for arch in $ARCHS; do
    cat "$DIST_DIR/DockerSandboxes-linux-${arch}-rockylinux8.tar.gz.sha256"
  done
  echo '```'
}

echo "==> Release $RELEASE_TAG on $REPO (prerelease: $PRERELEASE)"
for f in "${ASSETS[@]}"; do
  printf '    %-62s %s\n' "$f" "$(wc -c < "$DIST_DIR/$f" | awk '{printf "%.1f MB", $1 / 1e6}')"
done

if [ "$DRY_RUN" = 1 ]; then
  echo "==> Dry run: release notes would be"
  release_notes | sed 's/^/    | /'
  echo "==> Dry run: nothing was sent to GitHub"
  exit 0
fi

# -------------------------------------------------------------------- api --
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token 2>/dev/null || true)"; fi
[ -n "$TOKEN" ] || die "no GitHub token: set GITHUB_TOKEN (or GH_TOKEN, or run 'gh auth login')"

# request METHOD URL [curl args...]: sets HTTP_CODE and BODY. The token goes in
# through a config file descriptor so it never appears in the process list.
request() {
  local method=$1 url=$2 out; shift 2
  out="$(curl -sS -X "$method" \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
    -w '\n%{http_code}' "$@" "$url")" || die "curl failed: $method $url"
  HTTP_CODE="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}

# expect CODE... : die with GitHub's own message unless the last request returned one of them.
expect() {
  local c
  for c in "$@"; do [ "$HTTP_CODE" = "$c" ] && return 0; done
  die "GitHub returned HTTP $HTTP_CODE: $(printf '%s' "$BODY" | jq -r '[.message, (.errors // [] | map(.code // .message) | join(", "))] | map(select(. != null and . != "")) | join(" - ")' 2>/dev/null || printf '%s' "$BODY")"
}

echo "==> Checking access to $REPO"
request GET "$API/repos/$REPO"
expect 200
printf '%s' "$BODY" | jq -e '.permissions.push // .permissions.admin' >/dev/null \
  || die "this token cannot write to $REPO"

# Drafts do not show up under /releases/tags/<tag>, so look through the list.
request GET "$API/repos/$REPO/releases?per_page=100"
expect 200
RELEASE="$(printf '%s' "$BODY" | jq -c --arg t "$RELEASE_TAG" 'map(select(.tag_name == $t)) | first // empty')"

if [ -n "$RELEASE" ]; then
  [ "$REPLACE" = 1 ] || die "release $RELEASE_TAG already exists ($(jq -r .html_url <<<"$RELEASE")); use --replace to replace its assets"
  echo "==> Reusing existing release $RELEASE_TAG"
else
  echo "==> Creating draft release $RELEASE_TAG"
  payload="$(jq -n --arg tag "$RELEASE_TAG" --arg name "SBX ${RELEASE_TAG} for AlmaLinux 8 (tarball)" \
    --arg body "$(release_notes)" --arg target "$TARGET" --argjson pre "$PRERELEASE" \
    '{tag_name: $tag, name: $name, body: $body, draft: true, prerelease: $pre}
     + (if $target != "" then {target_commitish: $target} else {} end)')"
  request POST "$API/repos/$REPO/releases" -H "Content-Type: application/json" -d "$payload"
  expect 201
  RELEASE="$BODY"
fi
RELEASE_ID="$(jq -r .id <<<"$RELEASE")"

# ----------------------------------------------------------------- upload --
for f in "${ASSETS[@]}"; do
  old_id="$(jq -r --arg n "$f" '.assets // [] | map(select(.name == $n)) | first.id // empty' <<<"$RELEASE")"
  if [ -n "$old_id" ]; then
    echo "==> Deleting old $f"
    request DELETE "$API/repos/$REPO/releases/assets/$old_id"
    expect 204
  fi

  case "$f" in *.sha256) ctype="text/plain" ;; *) ctype="application/gzip" ;; esac
  echo "==> Uploading $f"
  request POST "$UPLOADS/repos/$REPO/releases/$RELEASE_ID/assets?name=$f" \
    -H "Content-Type: $ctype" --data-binary "@$DIST_DIR/$f"
  expect 201

  want_size="$(wc -c < "$DIST_DIR/$f" | tr -d ' ')"
  got_size="$(jq -r .size <<<"$BODY")"
  [ "$got_size" = "$want_size" ] || die "$f: GitHub has $got_size bytes, local file is $want_size"
  # GitHub reports a sha256 digest on assets; compare when present.
  digest="$(jq -r '.digest // empty' <<<"$BODY")"
  if [ -n "$digest" ]; then
    want_sha="$( (command -v sha256sum >/dev/null 2>&1 && sha256sum "$DIST_DIR/$f" || shasum -a 256 "$DIST_DIR/$f") | cut -d' ' -f1)"
    [ "$digest" = "sha256:$want_sha" ] || die "$f: GitHub digest $digest does not match local sha256:$want_sha"
  fi
done

# ---------------------------------------------------------------- publish --
if [ "$(jq -r .draft <<<"$RELEASE")" = true ] && [ "$KEEP_DRAFT" = 0 ]; then
  echo "==> Publishing $RELEASE_TAG"
  request PATCH "$API/repos/$REPO/releases/$RELEASE_ID" -H "Content-Type: application/json" -d '{"draft": false}'
  expect 200
  RELEASE="$BODY"
fi

echo
echo "==> Done: $(jq -r '.html_url + (if .draft then "  (draft)" else "" end)' <<<"$RELEASE")"
for f in "${ASSETS[@]}"; do
  echo "    https://github.com/$REPO/releases/download/$RELEASE_TAG/$f"
done
