#!/bin/bash
set -euo pipefail

gnome-shell --version | grep -E '^GNOME Shell 48\.'
export XDG_RUNTIME_DIR
XDG_RUNTIME_DIR=$(mktemp -d)
trap 'rm -rf "$XDG_RUNTIME_DIR"' EXIT
unset DISPLAY WAYLAND_DISPLAY
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME LIBGL_ALWAYS_SOFTWARE=1

dbus-run-session -- bash -eu <<'BASH'
logdir=$XDG_RUNTIME_DIR
export WAYLAND_DISPLAY=missioncenter-ci

gnome-shell --headless --wayland --no-x11 --virtual-monitor=1280x720 \
    --wayland-display="$WAYLAND_DISPLAY" > "$logdir/shell.log" 2>&1 &
shell_pid=$!
cleanup() {
    local status=$?
    if [[ -n ${app_pid:-} ]]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    kill "$shell_pid" 2>/dev/null || true
    wait "$shell_pid" 2>/dev/null || true
    if ((status != 0)); then
        tail -n 100 "$logdir/shell.log"
        if [[ -f $logdir/missioncenter.log ]]; then
            tail -n 100 "$logdir/missioncenter.log"
        fi
    fi
}
trap cleanup EXIT

for ((i = 0; i < 100; i++)); do
    [[ ! -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] || break
    kill -0 "$shell_pid"
    sleep .2
done
[[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]]

GDK_BACKEND=wayland GSK_RENDERER=cairo WAYLAND_DEBUG=client missioncenter > "$logdir/missioncenter.log" 2>&1 &
app_pid=$!
for ((i = 0; i < 150; i++)); do
    kill -0 "$app_pid" "$shell_pid"
    if grep -Eq 'xdg_toplevel[.#@][0-9]+\.set_title\("Mission Center"\)' "$logdir/missioncenter.log" &&
        grep -Eq 'wl_surface[.#@][0-9]+\.attach\(wl_buffer' "$logdir/missioncenter.log"; then
        echo 'Mission Center rendered a window on GNOME 48 Wayland.'
        exit 0
    fi
    sleep .2
done
echo 'Timed out waiting for the Mission Center Wayland window.' >&2
exit 1
BASH
