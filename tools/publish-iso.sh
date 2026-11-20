#!/bin/bash
#
# tools/publish-iso.sh - pins a Debian netinst ISO (maintainers only)
#
# 1) Downloads SHA256SUMS and SHA256SUMS.sign of that Debian release from
#    cdimage.debian.org and the ISO (or uses an ISO you already have)
# 2) Verifies the GPG signature of SHA256SUMS (pinned Debian CD signing key)
#    and the ISO against it
# 3) Uploads the ISO, SHA256SUMS, SHA256SUMS.sign and the signing key,
#    unchanged, as assets of the GitHub release debian-<version> of this repo
# 4) Updates DEBIAN_VERSION / DEBIAN_ISO_SHA256 in debianopen-setup.sh
#
# Then test an install, commit and push.
#
# Usage:
#   tools/publish-iso.sh <version> [--iso FILE]     e.g. tools/publish-iso.sh 12.15.0
#
# Requires: gh (logged in, with push access), gpg, curl
#
set -euo pipefail

DEBIAN_KEY_FPR="DF9B9C49EAA9298432589D76DA87E80D6294BE9B"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/debianopen-setup.sh"

VERSION=""
ISO_IN=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --iso)     ISO_IN="$2"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         VERSION="$1"; shift ;;
  esac
done
[ -n "$VERSION" ] || die "usage: tools/publish-iso.sh <version> [--iso FILE]"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version looks like 12.15.0, got: $VERSION"

for t in gh gpg curl shasum; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
REPO="$(cd "$ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner)" || die "gh cannot see this repo (gh auth login?)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/debianopen-publish.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ISO="debian-${VERSION}-arm64-netinst.iso"

base=""
for b in "https://cdimage.debian.org/cdimage/release/${VERSION}/arm64/iso-cd" \
         "https://cdimage.debian.org/cdimage/archive/${VERSION}/arm64/iso-cd"; do
  if curl -fsSL -o "$WORK/SHA256SUMS" "$b/SHA256SUMS" && curl -fsSL -o "$WORK/SHA256SUMS.sign" "$b/SHA256SUMS.sign"; then
    base="$b"; break
  fi
done
[ -n "$base" ] || die "could not find SHA256SUMS for Debian $VERSION on cdimage.debian.org"
log "Checksums from $base"

log "Verifying the GPG signature of SHA256SUMS"
GNUPGHOME="$WORK/gnupg"; export GNUPGHOME
mkdir -m 700 "$GNUPGHOME"
curl -fsSL -o "$WORK/debian-cd-signing-key.asc" "https://keyring.debian.org/pks/lookup?op=get&search=0x${DEBIAN_KEY_FPR}"
gpg --batch --quiet --import "$WORK/debian-cd-signing-key.asc" 2>/dev/null
gpg --batch --status-fd 1 --verify "$WORK/SHA256SUMS.sign" "$WORK/SHA256SUMS" 2>/dev/null \
  | awk -v f="$DEBIAN_KEY_FPR" '$2 == "VALIDSIG" && ($3 == f || $NF == f) { ok = 1 } END { exit ok ? 0 : 1 }' \
  || die "GPG signature could not be verified"
gpgconf --kill all >/dev/null 2>&1 || true

if [ -n "$ISO_IN" ]; then
  cp "$ISO_IN" "$WORK/$ISO"
else
  log "Downloading $ISO"
  curl -fL --progress-bar -o "$WORK/$ISO" "$base/$ISO"
fi
SHA="$(shasum -a 256 "$WORK/$ISO" | awk '{ print $1 }')"
awk -v h="$SHA" -v f="$ISO" '$1 == h && $2 == f { ok = 1 } END { exit ok ? 0 : 1 }' "$WORK/SHA256SUMS" \
  || die "$ISO ($SHA) is not in the signed SHA256SUMS"

TAG="debian-$VERSION"
log "Uploading to $REPO release $TAG"
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$REPO" --latest=false --title "Debian $VERSION arm64 netinst" --notes "Unmodified mirror of the upstream Debian $VERSION arm64 netinst ISO, with its upstream SHA256SUMS, the GPG signature SHA256SUMS.sign and the Debian CD signing key. Pinned by debianopen-setup.sh, which still checks the signature against the pinned fingerprint \`$DEBIAN_KEY_FPR\`.

sha256: \`$SHA\`
upstream: $base/$ISO"
fi
gh release upload "$TAG" --repo "$REPO" --clobber "$WORK/$ISO" "$WORK/SHA256SUMS" "$WORK/SHA256SUMS.sign" "$WORK/debian-cd-signing-key.asc"

log "Updating debianopen-setup.sh"
sed -i '' \
  -e "s|^DEBIAN_VERSION=\".*\"|DEBIAN_VERSION=\"$VERSION\"|" \
  -e "s|^DEBIAN_ISO_SHA256=\"[0-9a-f]*\"|DEBIAN_ISO_SHA256=\"$SHA\"|" \
  "$SETUP"
grep -E '^DEBIAN_(VERSION|ISO_SHA256)=' "$SETUP"
printf '\nDone. Test an install, then commit and push debianopen-setup.sh.\n'
