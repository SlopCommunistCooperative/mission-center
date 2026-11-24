# Building Mission Center

Mission Center can be built natively for your host OS or packaged as an AppImage, Snap or Flatpak.

## Debian 13 (GNOME 48 Wayland)

The **Debian 13 package** GitHub Actions workflow builds and uploads `.deb` artifacts for `amd64` and `arm64`. The
packages use Debian's GTK 4, GLib and libadwaita, with no private toolkit copies. A compatible replacement for Debian's
`libgtk-4-1` package is used automatically if it is installed. CI verifies the installed GTK library and opens both the
main and keyboard shortcuts windows under headless Mutter 48, the GNOME Wayland compositor.

Download the `.deb` for your architecture (`dpkg --print-architecture`) from [GitHub Releases](https://github.com/yeyebbc/mission-center/releases/latest)
or extract it from an Actions artifact, then install it:

```bash
sudo apt install ./missioncenter_*_$(dpkg --print-architecture).deb
```

For a local build, use a recursive checkout and run the same build in a disposable container:

```bash
docker run --rm -v "$PWD:/hostfs" -w /hostfs debian:13 \
    bash support/debian/build-package.sh "$(git show -s --format=%ct).$(git rev-parse --short=12 HEAD)"
```

The `.deb` is written to `_build/debs/`.

## Native

**Requirements:**

| Dependency                 | Comment             | Minimum Version |
|----------------------------|---------------------|----------------:|
| Meson                      |                     |           1.0.2 |
| Rust                       |                     |            1.96 |
| CMake                      |                     |            3.15 |
| Python3                    |                     |            3.10 |
| Blueprint Compiler         |                     |          0.16.0 |
| patch                      | Used to patch NVTOP |             N/A |
| DRM development libraries  |                     |             N/A |
| GBM development libraries  |                     |             N/A |
| udev development libraries |                     |             N/A |
| GLib                       |                     |            2.84 |
| GTK 4                      |                     |            4.18 |
| libadwaita                 |                     |             1.7 |

**Build instructions**

```bash
# The build needs the Git submodules, so clone with `--recursive`
git clone --recursive https://gitlab.com/mission-center-devs/mission-center
cd mission-center

# On Debian 13, install the native build dependencies and provide Rust separately:
sudo apt install blueprint-compiler build-essential cmake desktop-file-utils gettext git libadwaita-1-dev libdbus-1-dev libdrm-dev libgbm-dev libudev-dev meson ninja-build patch pkgconf

BUILD_ROOT="$(pwd)/build-meson-debug"

meson setup "$BUILD_ROOT" -Dbuildtype=debug # Alternatively pass `-Dbuildtype=release` for a release build
ninja -C "$BUILD_ROOT"
```

### Running from the build directory

Running the app from the build directory (for development or debugging) requires some set up:

```bash
export PATH="$BUILD_ROOT/subprojects/magpie/src:$PATH"
export GSETTINGS_SCHEMA_DIR="$BUILD_ROOT/data"
export MC_MAGPIE_HW_DB="$BUILD_ROOT/subprojects/magpie/platform-linux/hwdb/hw.db"
export MC_RESOURCE_DIR="$BUILD_ROOT/resources"

glib-compile-schemas --strict --targetdir="$BUILD_ROOT/data" data
```

And then to run the app:

```bash
"$BUILD_ROOT/src/missioncenter"
```

### Installing

```bash
ninja -C "$BUILD_ROOT" install
```

And run the app from your launcher or from the command-line:

```bash
missioncenter
```

## AppImage

The AppImage can be built in two steps. Both steps are destructive since they install packages and replace system files,
so they should, ideally, be run in containers. The examples use Podman but Docker works just as well. The scripts are
meant to be run from the root of the source tree.

First, build Mission Center together with recent GTK and libadwaita releases in an Ubuntu 24.04 container. The result
is written to `_build/portable`:

```bash
podman run --rm -v "$(pwd)":/hostfs -e VERSION_STRING="$(git describe --tags --always)" \
    docker.io/library/ubuntu:24.04 bash /hostfs/support/build-with-gtk-libadwaita.sh
```

Then package it in an Arch Linux container:

```bash
podman run --rm -v "$(pwd)":/hostfs docker.io/library/archlinux:latest \
    bash -c 'cp -r /hostfs/_build/portable/usr / && bash /hostfs/support/create-appimage.sh'
```

The AppImage is written to the root of the source tree as `MissionCenter-<version>-<arch>.AppImage`. If building for
ARM64, use the `docker.io/pkgforge/archlinux:latest` image instead.

## Snap

The Snap package uses the output of the first AppImage step (`_build/portable`) and custom Snapcraft container, that
contains a fix that upstream won't merge.

After running the build step for the AppImage continue with:

```bash
mkdir -p snap/local
cp -r _build/portable/usr snap/local/
cp -r _build/portable/dependencies/* snap/local/

podman run --rm -v "$(pwd)":/project registry.gitlab.com/mission-center-devs/build-tools/snapcraft:x86-latest
```

The Snap is written to the root of the source tree as `mission-center_<version>_<arch>.snap`. If building for ARM64, use
the `arm-latest` tag.

## Flatpak

**Requirements:**

* Flatpak
* Flatpak-Builder

Add the `flathub` repo if not already present:

```bash
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
```

Install the required Flatpak runtimes and SDKs:

```bash
flatpak install -y \
    org.freedesktop.Platform//26.08 \
    org.freedesktop.Sdk//26.08 \
    org.gnome.Platform//51 \
    org.gnome.Sdk//51
```

Finally build a Flatpak package:

```bash
cd flatpak
flatpak-builder --repo=repo --ccache --force-clean build io.missioncenter.MissionCenter.json
flatpak build-bundle repo missioncenter.flatpak io.missioncenter.MissionCenter
```

Install the package:

```bash
flatpak uninstall -y io.missioncenter.MissionCenter
flatpak install -y missioncenter.flatpak
```

Run the app from your launcher or from the command-line:

```bash
flatpak run io.missioncenter.MissionCenter
```
