#!/bin/bash
set -euo pipefail

mutter --version | grep -E '^mutter 48\.'
export XDG_RUNTIME_DIR
XDG_RUNTIME_DIR=$(mktemp -d)
trap 'rm -rf "$XDG_RUNTIME_DIR"' EXIT
unset DISPLAY WAYLAND_DISPLAY
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME LIBGL_ALWAYS_SOFTWARE=1

dbus-run-session -- bash -eu <<'BASH'
logdir=$XDG_RUNTIME_DIR
export WAYLAND_DISPLAY=missioncenter-ci

mutter --headless --wayland --no-x11 --virtual-monitor=1280x720 \
    --wayland-display="$WAYLAND_DISPLAY" > "$logdir/mutter.log" 2>&1 &
mutter_pid=$!
cleanup() {
    local status=$?
    if [[ -n ${app_pid:-} ]]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    kill "$mutter_pid" 2>/dev/null || true
    wait "$mutter_pid" 2>/dev/null || true
    if ((status != 0)); then
        tail -n 100 "$logdir/mutter.log"
        if [[ -f $logdir/missioncenter.log ]]; then
            tail -n 100 "$logdir/missioncenter.log"
        fi
    fi
}
trap cleanup EXIT

for ((i = 0; i < 100; i++)); do
    [[ ! -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] || break
    kill -0 "$mutter_pid"
    sleep .2
done
[[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]]

GDK_BACKEND=wayland GSK_RENDERER=cairo WAYLAND_DEBUG=client missioncenter > "$logdir/missioncenter.log" 2>&1 &
app_pid=$!
wait_for_window() {
    local title=$1
    for ((i = 0; i < 150; i++)); do
        kill -0 "$app_pid"
        kill -0 "$mutter_pid"
        if grep -Fq ".set_title(\"$title\")" "$logdir/missioncenter.log" &&
            grep -Eq 'wl_surface[.#@][0-9]+\.attach\(wl_buffer' "$logdir/missioncenter.log"; then
            return 0
        fi
        sleep .2
    done
    echo "Timed out waiting for the $title Wayland window." >&2
    return 1
}

wait_for_window 'Mission Center'
gtk_library=$(awk '$6 ~ /\/libgtk-4\.so\.1(\.|$)/ {print $6; exit}' "/proc/$app_pid/maps")
dpkg-query -L libgtk-4-1 | grep -Fx "$gtk_library"
gapplication action io.missioncenter.MissionCenter keyboard-shortcuts
wait_for_window 'Keyboard Shortcuts'
echo 'Mission Center and its shortcuts window opened on GNOME 48 Wayland using system GTK.'
BASH
