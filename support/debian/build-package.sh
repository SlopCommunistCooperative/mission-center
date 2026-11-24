#!/bin/bash
set -euo pipefail

# Run as root at the checkout root in a disposable Debian 13 container.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates dpkg-dev patchelf python3-setuptools xz-utils

upstream_version=$(awk -F"'" '/^[[:space:]]*version:/ { print $2; exit }' meson.build)
version="$upstream_version+git${1:?Pass the commit timestamp and short SHA}-1"
dpkg --validate-version "$version"
arch=$(dpkg --print-architecture)
multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)

source_dir=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
portable="$work/portable"
SRC_PATH="$source_dir" OUT_PATH="$portable" BUILD_DIR="$work/build" \
    LICENSE_DIR="$work/licenses" VERSION_STRING="$upstream_version" \
    bash support/build-with-gtk-libadwaita.sh

output="$PWD/_build/debs"
mkdir -p "$output"
cd "$work"
package=debian/missioncenter
private_dir="$package/usr/lib/missioncenter"
install -d "$package/DEBIAN" "$private_dir/share/icons"
cp -a "$portable/usr" "$package/"
cp -a "$portable/dependencies/usr/share/icons/Adwaita" "$private_dir/share/icons/"
schemas="$private_dir/share/glib-2.0/schemas"
install -d "$schemas"
cp "$portable/dependencies/usr/share/glib-2.0/schemas/"org.gtk.gtk4.*.gschema.xml "$schemas/"
glib-compile-schemas --strict "$schemas"
cp -a "$portable/dependencies/usr/lib/$multiarch/"lib*.so.[0-9]* "$private_dir/"

# Keep the newer stack private, without setting LD_LIBRARY_PATH for subprocesses.
mv "$package/usr/bin/missioncenter" "$private_dir/"
patchelf --force-rpath --set-rpath '$ORIGIN' "$private_dir/missioncenter"
cat > "$package/usr/bin/missioncenter" <<'EOF'
#!/bin/sh
export XDG_DATA_DIRS="/usr/lib/missioncenter/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec /usr/lib/missioncenter/missioncenter "$@"
EOF
chmod 0755 "$package/usr/bin/missioncenter"
install -Dm0644 "$source_dir/COPYING" "$package/usr/share/doc/missioncenter/copyright"
cp -a "$work/licenses" "$package/usr/share/doc/missioncenter/"

cat > debian/control <<'EOF'
Source: missioncenter
Section: utils
Priority: optional
Maintainer: Mission Center Developers <mail@romeocalota.me>

Package: missioncenter
Architecture: any
Description: GTK system resource monitor
EOF

# Teach dpkg-shlibdeps which SONAMEs this package provides, but do not advertise
# private libraries to other Debian packages.
elfs=("$private_dir/missioncenter" "$package/usr/bin/missioncenter-magpie")
for library in "$private_dir/"lib*.so.[0-9]*; do
    [[ ! -L "$library" ]] || continue
    soname=$(patchelf --print-soname "$library")
    printf '%s %s missioncenter\n' "${soname%%.so.*}" "${soname#*.so.}" >> "$package/DEBIAN/shlibs"
    elfs+=("$library")
done
depends=$(dpkg-shlibdeps -O -xmissioncenter -l"$private_dir" "${elfs[@]}")
rm "$package/DEBIAN/shlibs"

cat > "$package/DEBIAN/control" <<EOF
Package: missioncenter
Version: $version
Architecture: $arch
Section: utils
Priority: optional
Maintainer: Mission Center Developers <mail@romeocalota.me>
Depends: ${depends#shlibs:Depends=}, adwaita-icon-theme, fontconfig, hicolor-icon-theme, librsvg2-common
Homepage: https://missioncenter.io/
Description: GTK system resource monitor
 Monitor CPU, memory, disk, network and GPU usage, applications and services.
EOF

dpkg-deb --root-owner-group --build "$package" "$output/missioncenter_${version}_${arch}.deb"
