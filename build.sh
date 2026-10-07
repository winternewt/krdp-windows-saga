#!/bin/bash
# Rebuild Debian 13 (trixie) krdp / kpipewire with the patches in this repo.
#
#   ./build.sh krdp       [workdir]
#   ./build.sh kpipewire  [workdir]
#
# Needs: deb-src enabled for trixie, and `sudo apt build-dep <package>` once.
# Produces .deb files in <workdir> (default: ./build-<package>), versioned
# <debian version>+local1. That sorts above Debian stable updates
# (+deb13uN), so apt won't replace it with one; check `apt-cache policy` before upgrades.
set -euo pipefail

pkg="${1:?usage: $0 krdp|kpipewire [workdir]}"
case "$pkg" in krdp|kpipewire) ;; *) echo "unknown package: $pkg" >&2; exit 1 ;; esac

here="$(cd "$(dirname "$0")" && pwd)"
work="${2:-$PWD/build-$pkg}"
# A rerun in the same directory would append the series twice.
[ -e "$work" ] && { echo "workdir $work exists; remove it or pass a fresh one" >&2; exit 1; }
mkdir -p "$work"
cd "$work"

apt-get source "$pkg"
src="$(find . -maxdepth 1 -type d -name "$pkg-*" | head -1)"
cd "$src"

# Add our patches after Debian's own; dpkg-source applies them during the build.
cp "$here/$pkg/patches/"*.patch debian/patches/
cat "$here/$pkg/patches/series" >> debian/patches/series

version="$(dpkg-parsechangelog -S Version)+local1"
{
    printf '%s (%s) trixie; urgency=medium\n\n' "$pkg" "$version"
    printf '  * Local build with patches from krdp-windows-saga.\n\n'
    printf ' -- %s <%s>  %s\n\n' "${DEBFULLNAME:-Local Builder}" "${DEBEMAIL:-local@localhost}" "$(date -R)"
    cat debian/changelog
} > debian/changelog.new
mv debian/changelog.new debian/changelog

DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -us -uc -b

echo
echo "Built:"
ls -1 "$work"/*.deb
