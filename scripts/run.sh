#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_DIR=".build/Murmur.app"

./scripts/build.sh

EXPECTED="$(cd "${APP_DIR}/Contents/MacOS" && pwd)/Murmur"

# Quit every running copy by pid.
#
# Deliberately NOT `osascript -e 'tell application id "com.railssquad.murmur"'`:
# LaunchServices resolves that bundle id to whichever bundle it has registered —
# usually /Applications/Murmur.app, not our build — so it can miss the instance
# we meant to kill and *launch the stale release* instead.
if pgrep -x Murmur >/dev/null; then
    for pid in $(pgrep -x Murmur); do
        echo "Quitting: $(ps -o comm= -p "${pid}" 2>/dev/null || echo "pid ${pid}")"
        kill "${pid}" 2>/dev/null || true
    done
    for _ in $(seq 1 50); do
        pgrep -x Murmur >/dev/null || break
        sleep 0.1
    done
    pkill -9 -x Murmur 2>/dev/null || true
    sleep 0.3
fi

open "${APP_DIR}"

# Wait for it to come up.
for _ in $(seq 1 50); do
    pgrep -x Murmur >/dev/null && break
    sleep 0.1
done
sleep 0.4   # let any second instance register before we judge

RUNNING="$(pgrep -x Murmur || true)"
if [ -z "${RUNNING}" ]; then
    echo "ERROR: Murmur did not start" >&2
    exit 1
fi

# Check *every* instance, not just the first: the failure we keep hitting is a
# stale copy running alongside the new one, which a head -1 check happily misses.
STRAYS=""
COUNT=0
for pid in ${RUNNING}; do
    COUNT=$((COUNT + 1))
    path="$(ps -o comm= -p "${pid}" 2>/dev/null || true)"
    [ "${path}" = "${EXPECTED}" ] || STRAYS="${STRAYS}  ${path} (pid ${pid})
"
done

if [ -n "${STRAYS}" ]; then
    echo "ERROR: a stale Murmur is still running:" >&2
    printf "%s" "${STRAYS}" >&2
    exit 1
fi
if [ "${COUNT}" -ne 1 ]; then
    echo "ERROR: ${COUNT} instances of the dev build are running; expected 1" >&2
    exit 1
fi

echo "Running: ${EXPECTED}"
