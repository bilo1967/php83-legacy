#!/usr/bin/env bash
# Experimental: rebuild Sury PECL Debian source packages for PHP 8.4 on Ubuntu 20.04.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export DEBEMAIL="build@localhost"
export DEBFULLNAME="PHP 8.4 Legacy Build"
export TZ=Etc/UTC
export PHP_VERSIONS=8.4
export PHP_DEFAULT_VERSION=8.4
export DEB_BUILD_OPTIONS="nocheck parallel=4"
umask 022

PHP_DEBS=/php-debs
OUT=/out
WORK=/work
mkdir -p "$OUT" "$WORK"

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl python3 dpkg-dev devscripts debhelper \
  build-essential pkg-config autoconf automake libtool re2c \
  libmagickwand-dev libmemcached-dev libsasl2-dev zlib1g-dev \
  liblz4-dev libzstd-dev libssl-dev libhashkit-dev \
  libpcre3-dev libxml2-dev

# Ubuntu Focal ships dh-php 0.35, but the current Sury PECL sources
# require dh-php >= 5.5. Install Sury's newer architecture-independent
# helper ONLY inside this throwaway build container.
DH_PHP_VERSION='5.22+0~20260903.42+ubuntu22.04~1.gbpf43e56'
DH_PHP_DEB="dh-php_${DH_PHP_VERSION}_all.deb"
curl -fL --retry 3 \
  "https://packages.sury.org/php/pool/main/d/dh-php/${DH_PHP_DEB}" \
  -o "/tmp/${DH_PHP_DEB}"
apt-get install -y --no-install-recommends "/tmp/${DH_PHP_DEB}"
dpkg-query -W -f='${Version}\n' dh-php
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' dh-php)" ge '5.5~'

# Use only the PHP packages from the selected, checksum-verified artifact.
# Local packages are installed together so that APT may resolve their internal dependencies.
mapfile -t php_packages < <(find "$PHP_DEBS" -maxdepth 1 -type f -name '*.deb' \
  \( -name 'php8.4-common_*' -o -name 'php8.4-cli_*' -o -name 'php8.4-dev_*' \
  -o -name 'php8.4-opcache_*' -o -name 'php8.4-readline_*' \) | sort)
if (( ${#php_packages[@]} != 5 )); then
  echo "Expected five base PHP packages; got ${#php_packages[@]}" >&2
  exit 1
fi
apt-get install -y --no-install-recommends "${php_packages[@]}"
php8.4 -v
php-config8.4 --version
[[ $(php-config8.4 --phpapi) == 20240924 ]]

# Fetch the Ubuntu 22.04 Sury .dsc and the exact files listed in its SHA256 stanza.
# No generated upstream source archives are substituted for Sury's Debian source.
fetch_source() {
  local package=$1 dest=$2
  mkdir -p "$dest"
  python3 - "$package" "$dest" <<'PY'
import hashlib, html.parser, pathlib, re, sys, urllib.request
package, dest = sys.argv[1], pathlib.Path(sys.argv[2])
base = f'https://packages.sury.org/php/pool/main/p/{package}/'
class Links(html.parser.HTMLParser):
    def __init__(self): super().__init__(); self.hrefs = []
    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            href = dict(attrs).get('href', '')
            if href: self.hrefs.append(href)
links = Links()
links.feed(urllib.request.urlopen(base, timeout=60).read().decode())
# Currently a single Ubuntu 22.04 packaging series per extension.
candidates = sorted(h for h in links.hrefs if
    re.fullmatch(re.escape(package) + r'_[A-Za-z0-9.+~%-]+ubuntu22\.04[A-Za-z0-9.+~%-]*\.dsc', h))
if len(candidates) != 1:
    raise SystemExit(f'Expected exactly one Ubuntu 22.04 .dsc for {package}, got {candidates}')
dsc_name = candidates[0]
dsc = urllib.request.urlopen(base + dsc_name, timeout=60).read()
(dest / dsc_name).write_bytes(dsc)
content = dsc.decode()
match = re.search(r'^Checksums-Sha256:\s*\n((?: [^\n]+\n)+)', content, re.M)
if not match: raise SystemExit('Missing SHA256 section in ' + dsc_name)
files = []
for line in match.group(1).splitlines():
    sha, size, name = line.split()
    if not re.fullmatch(r'[A-Za-z0-9_.+~%-]+', name): raise SystemExit('Unsafe filename')
    files.append((sha, int(size), name))
for expected, size, name in files:
    data = urllib.request.urlopen(base + name, timeout=120).read()
    if len(data) != size or hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit('Integrity mismatch: ' + name)
    (dest / name).write_bytes(data)
print(dsc_name)
PY
}

# Rebuild Sury's packaging for one PHP version only.  In particular we never
# fabricate .deb packages from .so files or replace the dh-php install scripts.
# NOTE: These are compatibility patches, not a generic Sury packaging solution.
prepare_control() {
  local srcdir=$1 package=$2
  python3 - "$srcdir" "$package" <<'PY'
import pathlib, re, sys
root, package = pathlib.Path(sys.argv[1]), sys.argv[2]
control = root/'debian/control'
s = control.read_text()
parts = re.split(r'\n(?=Package: )', s)
header = parts[0]
# php-all-dev would select PHP versions not present in this build environment.
header = re.sub(r'php-all-dev\s*\([^)]*\)', 'php8.4-dev', header)
header = re.sub(r'\bphp-all-dev\b', 'php8.4-dev', header)
# Restrict extension build dependencies to PHP 8.4.
header = re.sub(r'php[0-9]+\.[0-9]+-(apcu|igbinary|msgpack)\b',
                r'php8.4-\1', header)
header = re.sub(r'php-(apcu|igbinary|msgpack)-all-dev\s*\([^)]*\)',
                r'php8.4-\1', header)
header = re.sub(r'php-(apcu|igbinary|msgpack)-all-dev\b',
                r'php8.4-\1', header)
# Rebuild ONLY php8.4-$extension, retaining Sury's metadata and maintainer scripts.
kept = [p for p in parts[1:] if re.match(r'Package: php8\.3-' + re.escape(package[4:]) + r'\s*$', p.splitlines()[0])]
if len(kept) != 1:
    raise SystemExit(f'Cannot identify unique php8.4 binary stanza in {control}: {[p.splitlines()[0] for p in parts[1:]]}')
control.write_text(header.rstrip() + '\n\n' + kept[0].lstrip())
print('Selected binary package:', kept[0].splitlines()[0])
PY
  # Sury enables igbinary for Redis, but not msgpack. Both serializers
  # are required for compatibility with the existing Bellatrix installation.
  if [[ "$package" == php-redis ]]; then
    python3 - "$srcdir/debian/rules" <<'PYREDIS'
from pathlib import Path
import sys
rules = Path(sys.argv[1])
text = rules.read_text()
flag = '--enable-redis-igbinary'
if text.count(flag) != 1 or '--enable-redis-msgpack' in text:
    raise SystemExit('Unexpected Redis configure flags in debian/rules; review packaging')
rules.write_text(text.replace(flag, flag + ' --enable-redis-msgpack', 1))
print('Redis: enabled msgpack serializer in debian/rules')
PYREDIS
  fi
  # Do not silently rely on the distro default PHP during dh-php package builds.
  grep -R "pkg-pecl.mk" "$srcdir/debian/rules" || true
  (cd "$srcdir" && dch --local '+legacy1~ubuntu20.04' --distribution focal \
     'Rebuild Sury PECL packaging for Ubuntu 20.04 / PHP 8.4 only')
}

# Build base serializers first, then their dependents.
for ext in apcu igbinary msgpack redis imagick memcached; do
  package="php-$ext"
  echo "===== Building $package ====="
  src="$WORK/$package"
  fetch_source "$package" "$src"
  dsc=$(find "$src" -maxdepth 1 -name '*.dsc' -print -quit)
  (cd "$src" && dpkg-source -x "$dsc")
  sourcedir=$(find "$src" -mindepth 1 -maxdepth 1 -type d -print -quit)
  [[ -n "$sourcedir" ]]
  prepare_control "$sourcedir" "$package"
  # The upstream package's original dh-php build rules are preserved.
  (cd "$sourcedir" && dpkg-buildpackage -b -us -uc -j4)
  mapfile -t produced < <(find "$src" -maxdepth 1 -name "php8.4-${ext}_*.deb" -type f | sort)
  if (( ${#produced[@]} != 1 )); then
    echo "Expected exactly one php8.4-$ext Debian package" >&2
    exit 1
  fi
  cp "${produced[0]}" "$OUT/"
  dpkg-deb -f "${produced[0]}" Package Version Depends
  if [[ $ext == apcu || $ext == igbinary || $ext == msgpack ]]; then
    apt-get install -y --no-install-recommends "${produced[0]}"
  fi
done

(cd "$OUT" && sha256sum ./*.deb > SHA256SUMS)
for file in "$OUT"/*.deb; do
  dpkg-deb -c "$file" | grep -E '20240924|/etc/php/8.4/' || true
done
