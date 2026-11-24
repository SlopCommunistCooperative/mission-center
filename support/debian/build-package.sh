#!/bin/bash
set -euo pipefail

# Run as root at the checkout root in a disposable Debian 13 container.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    blueprint-compiler build-essential ca-certificates cmake curl desktop-file-utils \
    dpkg-dev gettext libadwaita-1-dev libdbus-1-dev libdrm-dev libgbm-dev libudev-dev \
    meson ninja-build patch pkgconf

upstream_version=$(awk -F"'" '/^[[:space:]]*version:/ { print $2; exit }' meson.build)
version="$upstream_version+git${1:?Pass the commit timestamp and short SHA}-1"
dpkg --validate-version "$version"
arch=$(dpkg --print-architecture)

source_dir=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export RUSTUP_HOME="$work/rustup"
export CARGO_HOME="$work/cargo"
curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs |
    sh -s -- --profile=minimal --default-toolchain=1.99.1 --no-modify-path -y
export PATH="$CARGO_HOME/bin:$PATH"

meson setup "$work/build" --prefix=/usr --buildtype=release -Dversion="$upstream_version"
meson compile -C "$work/build"

package="$work/debian/missioncenter"
DESTDIR="$package" meson install -C "$work/build" --no-rebuild
strip --strip-unneeded "$package/usr/bin/missioncenter" "$package/usr/bin/missioncenter-magpie"
install -d "$package/DEBIAN"
install -Dm0644 "$source_dir/COPYING" "$package/usr/share/doc/missioncenter/copyright"

output="$source_dir/_build/debs"
mkdir -p "$output"
cd "$work"

cat > debian/control <<'EOF'
Source: missioncenter
Section: utils
Priority: optional
Maintainer: Mission Center Developers <mail@romeocalota.me>

Package: missioncenter
Architecture: any
Description: GTK system resource monitor
EOF

depends=$(dpkg-shlibdeps -O "$package/usr/bin/missioncenter" "$package/usr/bin/missioncenter-magpie")

cat > "$package/DEBIAN/control" <<EOF
Package: missioncenter
Version: $version
Architecture: $arch
Section: utils
Priority: optional
Maintainer: Mission Center Developers <mail@romeocalota.me>
Depends: ${depends#shlibs:Depends=}, librsvg2-common
Homepage: https://missioncenter.io/
Description: GTK system resource monitor
 Monitor CPU, memory, disk, network and GPU usage, applications and services.
EOF

dpkg-deb --root-owner-group --build "$package" "$output/missioncenter_${version}_${arch}.deb"
