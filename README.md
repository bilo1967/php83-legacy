# PHP 8.3 packages for Ubuntu 20.04 (Focal)

Unofficial PHP 8.3 Debian packages for **Ubuntu 20.04 LTS (Focal), amd64**, built using the PHP packaging published by [Ondřej Surý](https://packages.sury.org/php/) and adapted to run on Focal.

This repository is a fork of [Niek/php7](https://github.com/Niek/php7), whose GitHub Actions / Docker build approach was used as the starting point. Thanks to both projects and their maintainers.

> **Unofficial, experimental build.** Not affiliated with or supported by Ondřej Surý, Ubuntu, or PHP. Ubuntu 20.04 is outside standard support. Building a newer PHP does **not** update or secure the underlying operating system or its libraries. Prefer a supported Ubuntu release for production systems.

## Build status and scope

- PHP: **8.3.36**, packaged as `.deb` files for **Ubuntu 20.04 amd64**.
- PECL extensions: APCu **5.1.28**, igbinary **3.2.16**, msgpack **3.0.0**, Redis **6.3.0**, Imagick **3.8.1**, memcached **3.4.0**.
- The normal Debian/Sury package names and layouts are preserved where possible: `php8.3-cli`, `php8.3-fpm`, `php8.3-common`, `php8.3-mysql`, etc.
- Paths include `/usr/bin/php8.3`, `/usr/sbin/php-fpm8.3`, `/etc/php/8.3/`, and `/usr/lib/php/20230831/`.
- PHP-FPM and PECL packages were installed and exercised on two existing Ubuntu 20.04 servers: one running Nextcloud, the other Moodle 5. These are **limited real-world checks**, not an automated test suite or a guarantee for other deployments.
- Only **Ubuntu 20.04 / amd64** is currently targeted. The original fork's other Ubuntu and Debian targets are not supported here.

## Repository files

| File | Purpose |
| --- | --- |
| `.github/workflows/build.yml` | Manually build PHP Debian packages inside an Ubuntu 20.04 container. |
| `build.sh` | PHP source extraction, Debian packaging and package build. |
| `sources.sha256` | Pinned source archive names and SHA-256 checksums for PHP. |
| `.github/workflows/build-pecl.yml` | Manually build the six PECL extensions using packages from a previous PHP workflow run. |
| `build-pecl.sh` | Fetch and adapt PECL Debian packaging and compile extension packages. |

## Build PHP packages

1. Open **Actions → Build PHP 8.3 Legacy → Run workflow**.
2. Download the `php8.3-ubuntu20.04-amd64` artifact after the build finishes.
3. Save the resulting `.deb` files and `SHA256SUMS` in durable storage: GitHub Actions artifacts expire. Check the retention period in the workflow.

The build uses the Sury PHP 8.3 upstream source and Debian packaging selected in `sources.sha256`, building against Ubuntu 20.04 system libraries. A local `+legacy…ubuntu20.04` suffix distinguishes these packages from upstream distribution packages.

## Build PECL packages

1. Complete a PHP build first; note its **GitHub Actions run ID**.
2. Open **Actions → Build PHP 8.3 PECL (Ubuntu 20.04) → Run workflow** and supply that PHP build run ID.
3. Download the `php8.3-pecl-ubuntu20.04-amd64` artifact.
4. Retain the PHP and PECL artifacts together, including checksum files.

The PECL build uses the newly built `php8.3-dev` package, targets PHP 8.3 only, and builds igbinary/msgpack before Redis and memcached. Redis is configured with both igbinary and msgpack serializer support. These extensions are packaged as Debian `.deb` files, not copied manually into the PHP extension directory.

**Reproducibility note:** the PHP source archives are pinned by `sources.sha256`; PECL source selection currently depends on the script's source discovery. Pinning PECL source versions and checksums is recommended before relying on repeated builds over time.

## Installing packages

**Back up existing PHP configurations and record installed packages before upgrading.** The packages are intended to follow Sury's normal file layout, but installation behavior depends on the existing dpkg state and configuration.

Download the two artifact archives, extract them into separate folders, and install **only the packages actually required**. For an Apache + PHP-FPM deployment, a typical selection includes:

```text
php8.3-common php8.3-cli php8.3-fpm php8.3-opcache
php8.3-mysql php8.3-mbstring php8.3-xml php8.3-curl
php8.3-zip php8.3-gd php8.3-intl php8.3-ldap
php8.3-bcmath php8.3-soap php8.3-sqlite3
php8.3-apcu php8.3-redis php8.3-igbinary php8.3-msgpack
php8.3-imagick
```

Other modules (e.g. `php8.3-imap`, `php8.3-bz2`, `php8.3-gmp`, `php8.3-pspell`, `php8.3-memcached`) may be required by specific applications. Inspect local dependencies before installation.

**Do not install every `.deb` indiscriminately.** `libapache2-mod-php8.3`, `php8.3-cgi`, `php8.3-litespeed`, `php8.3-phpdbg`, `libphp8.3-embed`, and `php8.3-dev` serve different use cases and are not required for a normal Apache + PHP-FPM runtime. In particular, `php8.3-litespeed` caused service-management/removal problems during an initial test and is not recommended unless specifically needed and tested.

For locally extracted packages, first simulate the selected transaction (`apt-get -s install ./path/to/package.deb ...`), verify **removals and new dependencies**, then run the same command without `-s`. Avoid `--only-upgrade` if some selected modules are not installed yet. Do not run `apt autoremove` blindly on production systems.

For upgrades, dpkg ordinarily preserves locally modified conffiles. Nevertheless, inspect `/etc/php/8.3` and the generated `conf.d` symlinks: historical installations may have missing or disabled modules.

## PHP-FPM and module checks

```bash
php8.3 -v
php8.3 --ini
php8.3 -m
php-fpm8.3 -t
systemctl status php8.3-fpm
```

If `mysqli` or `pdo_mysql` reports missing `mysqlnd_*` symbols, check that `mysqlnd.so` is enabled **before** those extensions. With the Sury-style MySQL package, the template is in:

```text
/usr/share/php8.3-mysql/mysql/mysqlnd.ini
```

The expected installed configuration is `/etc/php/8.3/mods-available/mysqlnd.ini`, with links such as `10-mysqlnd.ini` for CLI and FPM. Confirm the `.so` exists in `/usr/lib/php/20230831/`, inspect module priorities, then use `phpenmod -v 8.3 -s cli mysqlnd` and the equivalent command for `fpm` as appropriate. One upgrade retained an incomplete older configuration; this was a host configuration issue, not evidence that a clean install necessarily behaves the same way.

When replacing a manually installed PHP-FPM in `/opt`, preserve its configuration and systemd unit for rollback, and ensure that the old and new FPM services do **not** bind the same socket simultaneously. Check application-specific pool, cron, OPcache and `php.ini` settings before switching traffic.

## Creating a release

Suggested first tag: **`v8.3.36-focal.1`** (mark as **pre-release** until installation testing is complete).

1. Go to **Releases → Draft a new release** and create the tag from the tested commit on `main`.
2. Attach the final **PHP** and **PECL** Debian packages from the two successful workflow artifacts, plus checksum files. Keep the source ZIPs/logs separate if the upload would become unwieldy.
3. State the exact target (Ubuntu 20.04, amd64), PHP version, PECL versions, and any known limitations.
4. Verify all intended files are attached before publishing. A release tag alone does not preserve expiring Actions artifacts.

For a long-term APT repository, additional repository metadata, package signing and a tested update strategy are needed; a GitHub release containing `.deb` files is **not** itself an APT repository.

## Acknowledgements and licensing

- [Niek/php7](https://github.com/Niek/php7): original workflow/build approach.
- [Ondřej Surý's PHP packages](https://packages.sury.org/php/): upstream PHP/extension Debian packaging.
- [PHP](https://www.php.net/): PHP upstream sources.

The original source code and packaging retain their respective licenses and copyright notices. This repository makes no claim of upstream endorsement.
