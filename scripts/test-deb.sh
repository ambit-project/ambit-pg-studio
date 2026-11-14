#!/usr/bin/env bash
# Installs build/deb/pg-studio_*.deb in clean containers, starts it under Xvfb, checks the window and the desktop
# entry, removes it and checks nothing is left. Needs docker.   scripts/test-deb.sh [image...]
set -euo pipefail
cd "$(dirname "$0")/.."
deb="$(ls build/deb/pg-studio_*_amd64.deb | head -1)"
images=("$@")
[[ ${#images[@]} -gt 0 ]] || images=(ubuntu:26.04 debian:13)
fixture=packages/pg_core/test/fixtures/shop
for image in "${images[@]}"; do
  echo "== $image"
  docker run --rm -v "$PWD/$deb:/tmp/pg-studio.deb:ro" -v "$PWD/$fixture:/tmp/shop:ro" "$image" bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq /tmp/pg-studio.deb xvfb xauth x11-utils desktop-file-utils >/dev/null 2>&1 \
      || { apt-get install -y /tmp/pg-studio.deb; exit 1; }
    echo "installed: $(dpkg-query -W -f="\${Package} \${Version}" pg-studio)"
    command -v pg-studio
    desktop-file-validate /usr/share/applications/dev.ambit.pg_studio.desktop && echo "desktop entry: valid"
    test -f /usr/share/icons/hicolor/256x256/apps/pg-studio.png && echo "icon: installed"
    # The program finds its libraries through RUNPATH $ORIGIN/lib; plugins rely on the engine the program loaded.
    { ldd /usr/lib/pg-studio/pg_studio; LD_LIBRARY_PATH=/usr/lib/pg-studio/lib ldd /usr/lib/pg-studio/lib/*.so; } \
      | grep "not found" && exit 1 || echo "libraries: all found"
    # The command line: problems of the fixture (exit 1: it has a syntax error on purpose) and an MCP handshake.
    set +e; pg-studio check /tmp/shop > /tmp/check.txt; code=$?; set -e
    [[ $code -eq 1 ]] && grep -q "error: syntax error" /tmp/check.txt && echo "cli check: $(tail -1 /tmp/check.txt) (exit $code)"
    reply="$(printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}" | pg-studio-cli mcp /tmp/shop)"
    echo "$reply" | grep -q "\"name\":\"pg-studio\"" && echo "cli mcp: initialize ok"
    # Started the way the menu does (Exec=pg-studio %F) with a folder, under a virtual display.
    Xvfb :99 -screen 0 1600x1000x24 >/dev/null 2>&1 &
    export DISPLAY=:99
    for i in $(seq 1 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
    # --terminal also opens the Terminal panel: a shell must start as a child of the app (3.0 spec 003).
    pg-studio --terminal /tmp/shop >/tmp/app.log 2>&1 &
    app=$!
    window=""
    for i in $(seq 1 100); do
      window="$(xwininfo -root -tree 2>/dev/null | grep -F "\"PG Studio\"" || true)"
      [[ -n "$window" ]] && break
      sleep 0.1
    done
    [[ -n "$window" ]] || { echo "no PG Studio window"; cat /tmp/app.log; exit 1; }
    echo "window: $(echo "$window" | head -1 | sed "s/^ *//")"
    kill -0 $app && echo "running: yes"
    shell=""
    for i in $(seq 1 100); do
      for f in /proc/[0-9]*/stat; do
        line="$(cat "$f" 2>/dev/null || true)"
        [[ -n "$line" ]] || continue
        ppid="$(echo "${line##*) }" | cut -d" " -f2)"
        comm="$(cat "${f%/stat}/comm" 2>/dev/null || true)"
        if [[ "$ppid" == "$app" && "$comm" =~ ^(bash|sh|dash|zsh)$ ]]; then shell="$comm"; fi
      done
      [[ -n "$shell" ]] && break
      sleep 0.1
    done
    [[ -n "$shell" ]] || { echo "no terminal shell"; cat /tmp/app.log; exit 1; }
    echo "terminal: $shell started by the app"
    kill $app
    files="$(dpkg -L pg-studio | while read -r f; do if [[ -f "$f" || -L "$f" ]]; then echo "$f"; fi; done)"
    echo "files: $(echo "$files" | wc -l)"
    dpkg -r pg-studio >/dev/null
    left=0
    for f in $files; do
      if [[ -e "$f" ]]; then echo "left: $f"; left=$((left+1)); fi
    done
    if [[ -e /usr/lib/pg-studio ]]; then echo "left: /usr/lib/pg-studio"; left=$((left+1)); fi
    if [[ $left -eq 0 ]]; then echo "removed: nothing left"; fi
    exit $left
  '
done
