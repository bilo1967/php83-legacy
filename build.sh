#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export DEBFULLNAME='php-legacy contributors'
export DEBEMAIL='noreply@github.com'

log() { printf '\n>>> %s\n' "$*"; }
trap 'printf "ERROR: build.sh failed at line %s (exit %s)\n" "$LINENO" "$?" >&2' ERR

# The first target is Ubuntu 20.04 (focal), amd64 only.
. /etc/os-release
if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 20.04 ]]; then
  echo "Unsupported build image: ${ID:-unknown} ${VERSION_ID:-unknown}" >&2
  exit 1
fi
codename=${VERSION_CODENAME:-focal}
: "${TARGET:=ubuntu20.04}"
: "${REVISION:=1}"
: "${JOBS:=4}"
[[ "$TARGET" == ubuntu20.04 ]] || { echo "Unexpected TARGET=$TARGET" >&2; exit 1; }
[[ "$REVISION" =~ ^[0-9]+$ ]] || { echo "REVISION must be numeric" >&2; exit 1; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "JOBS must be a positive integer" >&2; exit 1; }

# Prevent package post-install scripts from starting daemons in the build image.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d

log 'Installing native Ubuntu build tools'
apt-get update
apt-get install -y --no-install-recommends \
  build-essential devscripts equivs dpkg-dev debhelper \
  ca-certificates pkg-config curl

mkdir -p /build /out
cd /sources
log 'Verifying pinned upstream sources'
sha256sum -c /repo/sources.sha256

# Select the one pinned .dsc, without guessing package file names.
shopt -s nullglob
dsc_files=(php8.4_*.dsc)
((${#dsc_files[@]} == 1)) || {
  echo "Expected exactly one php8.4 .dsc; found ${#dsc_files[@]}" >&2
  exit 1
}
log 'Unpacking the unmodified Sury source package'
dpkg-source -x "${dsc_files[0]}" /build/php
cd /build/php

# Keep debian/rules, debian/control, packaging scripts, paths, and module
# configuration from Sury intact until a specific focal incompatibility
# is observed. In particular, do not reuse PHP 7.4 sed patches blindly.
upstream_version=$(dpkg-parsechangelog -S Version)
case "$upstream_version" in
  *8.4.27*) ;;
  *) echo "Unexpected PHP source version: $upstream_version" >&2; exit 1 ;;
esac
# Append the legacy revision after the complete Sury Debian version.
# A Debian tilde sorts before the corresponding unmodified Sury version.
package_version="${upstream_version}+legacy${REVISION}~ubuntu20.04"
log "Building package version $package_version"
dch --force-distribution --newversion "$package_version" \
  --distribution "$codename" \
  'Rebuild upstream Sury PHP 8.4 packages for Ubuntu 20.04.'

# Diagnose dependency failures instead of silently removing requirements.
log 'Installing the build dependencies specified by Sury'
mk-build-deps --install --remove \
  --tool 'apt-get -y --no-install-recommends' debian/control

export DEB_BUILD_OPTIONS="nocheck parallel=${JOBS}"
export DEB_BUILD_PROFILES=nocheck
log 'Building native Debian packages'
dpkg-buildpackage -us -uc -b -j"$JOBS"

log 'Publishing build artifacts'
cp /build/*.deb /out/
find /build -maxdepth 1 -type f \
  \( -name '*.buildinfo' -o -name '*.changes' \) \
  -exec cp {} /out/ \;
dpkg-query -W -f='${binary:Package}\t${Version}\n' > /out/build-dependencies.txt

# PHP 8.4 needs php-common >= 2:95~, newer than Focal's 2:75.
# This exact Sury architecture-independent package has been installed
# successfully in the Ubuntu 20.04 PECL build container.
# Bundle it with PHP packages, so deployments are self-contained.
php_common_version='101+0~20261021.78+ubuntu22.04~1.gbp53f25f'
php_common_file="php-common_${php_common_version}_all.deb"
php_common_url="https://packages.sury.org/php/pool/main/p/php-defaults/${php_common_file}"
log "Bundling Sury php-common 2:${php_common_version}"
curl -fsSL --retry 3 --retry-delay 2 "$php_common_url" -o "/out/${php_common_file}"
[[ "$(dpkg-deb -f "/out/${php_common_file}" Package)" == 'php-common' ]]
[[ "$(dpkg-deb -f "/out/${php_common_file}" Version)" == "2:${php_common_version}" ]]
[[ "$(dpkg-deb -f "/out/${php_common_file}" Architecture)" == 'all' ]]
printf '%s\n' "$php_common_url" > /out/php-common-source-url.txt

cd /out
sha256sum ./*.deb > SHA256SUMS
log 'Build finished successfully'
