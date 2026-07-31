#!/usr/bin/env bash
# The only documented way to run Inkwell. Every worktree gets its own
# backend port, storage directory, container, and (for iOS) simulator and
# DerivedData path, derived automatically from the worktree's path - see
# docs/runtime-isolation.md for why and scripts/inkwell-env.sh for how.
#
# Usage:
#   ./dev.sh              start everything (same as `up`)
#   ./dev.sh up           start the backend AND this worktree's simulator,
#                         Xcode project regenerated to match, app built,
#                         installed, and launched on screen - in one command
#   ./dev.sh down         stop it, and delete this worktree's simulator+DerivedData
#   ./dev.sh info         print this worktree's derived port/storage/etc
#   ./dev.sh ios generate regenerate the Xcode project alone, backend URL baked in
#   ./dev.sh ios sim      ensure+boot this worktree's simulator alone, print its UDID
#   ./dev.sh ios test     xcodebuild test against this worktree's simulator
#   ./dev.sh ios build    xcodebuild build against this worktree's simulator
#   ./dev.sh ios clean    delete this worktree's simulator+DerivedData now
#
# A booted per-worktree simulator tears itself down automatically: `down`
# deletes it, and so does shutting the device down by any other means (a
# watcher armed at boot notices). `ios clean` is only the backstop for when
# neither happened.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=scripts/inkwell-env.sh
source scripts/inkwell-env.sh
inkwell_derive
cd "$INKWELL_WORKTREE"

# Polls the backend's own healthcheck endpoint (same one docker-compose.yml
# uses) so the app isn't installed and launched against a backend that isn't
# actually answering yet.
inkwell_wait_for_backend() {
  local tries=0
  while [ "$tries" -lt 60 ]; do
    curl -fsS -o /dev/null "$INKWELL_BACKEND_URL/inklings" 2>/dev/null && return 0
    tries=$((tries + 1))
    sleep 1
  done
  return 1
}

# Builds (incrementally - xcodebuild itself skips work that's already up to
# date, so a rerun with nothing changed is fast), installs, and launches the
# app on this worktree's simulator, then brings Simulator.app to the front so
# it's actually visible rather than booted-but-hidden.
inkwell_build_install_launch() {
  local udid=$1 app_path log
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "inkwell: xcodebuild not found - skipping app launch" >&2
    return 1
  fi
  echo "inkwell: building Inkwell for the simulator" >&2
  log="${TMPDIR:-/tmp}/inkwell-build-$INKWELL_PROJECT_NAME.log"
  if ! xcodebuild build \
    -project ios/Inkwell.xcodeproj \
    -scheme Inkwell \
    -destination "id=$udid" \
    -derivedDataPath "$INKWELL_DERIVED_DATA" \
    >"$log" 2>&1; then
    echo "inkwell: build failed - not installing or launching (see $log)" >&2
    tail -n 40 "$log" >&2
    return 1
  fi
  app_path="$INKWELL_DERIVED_DATA/Build/Products/Debug-iphonesimulator/Inkwell.app"
  if [ ! -d "$app_path" ]; then
    echo "inkwell: built app not found at $app_path - not installing" >&2
    return 1
  fi
  xcrun simctl install "$udid" "$app_path"
  open -a Simulator
  xcrun simctl launch "$udid" "$INKWELL_BUNDLE_ID" >/dev/null
  echo "inkwell: Inkwell launched on $INKWELL_SIM_NAME" >&2
}

cmd="${1:-up}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  up)
    mkdir -p "$INKWELL_STORAGE_DIR"
    echo "inkwell: $INKWELL_PROJECT_NAME -> http://127.0.0.1:$INKWELL_PORT (storage: $INKWELL_STORAGE_DIR)"
    # One command brings up everything - containers and simulator together -
    # so the baked Info.plist URL can never drift from the live backend
    # port: both are derived and applied together, every time. Best-effort:
    # a missing Xcode/xcodegen must not stop the backend from starting.
    export INKWELL_BACKEND_URL
    ios_ready=0
    udid=""
    if command -v xcodegen >/dev/null 2>&1 && [ -d ios ]; then
      if inkwell_regenerate_ios_project && udid=$(inkwell_ensure_worktree_sim); then
        inkwell_boot_sim "$udid"
        echo "inkwell: simulator $INKWELL_SIM_NAME ($udid) ready"
        ios_ready=1
      else
        echo "inkwell: could not prepare the iOS side - continuing, the backend still starts" >&2
      fi
    else
      echo "inkwell: xcodegen not found or ios/ missing - skipping the iOS side, backend only" >&2
    fi

    # Backgrounded rather than exec'd, so there's a point after the backend
    # starts to build/install/launch the app - but still in the same process
    # group as this script, so a Ctrl-C at the terminal reaches it directly
    # exactly as it did when this was exec'd. The trap is belt-and-suspenders
    # for invocations where that isn't true (e.g. run via another wrapper).
    docker compose up --build "$@" &
    compose_pid=$!
    trap 'kill "$compose_pid" 2>/dev/null || true' INT TERM

    if [ "$ios_ready" -eq 1 ]; then
      if inkwell_wait_for_backend; then
        inkwell_build_install_launch "$udid" || true
      else
        echo "inkwell: backend did not become reachable - skipping app launch" >&2
      fi
    fi

    wait "$compose_pid"
    ;;
  down)
    # A cloned simulator costs 1-3GB, so bringing the stack down takes the
    # worktree's device with it, unconditionally. Runs even if compose failed
    # (docker not running, say) - the device is still this lane's to reclaim -
    # while still reporting compose's own exit status.
    rc=0
    docker compose down "$@" || rc=$?
    inkwell_teardown_worktree_sim
    exit "$rc"
    ;;
  ps|status)
    docker compose ps "$@"
    ;;
  logs)
    exec docker compose logs -f "$@"
    ;;
  info)
    cat <<EOF
worktree        $INKWELL_WORKTREE
project name    $INKWELL_PROJECT_NAME
backend url     $INKWELL_BACKEND_URL
storage dir     $INKWELL_STORAGE_DIR
derived data    $INKWELL_DERIVED_DATA
simulator name  $INKWELL_SIM_NAME
test proxy url  $INKWELL_TEST_PROXY_URL
EOF
    ;;
  ios)
    sub="${1:-generate}"
    [ $# -gt 0 ] && shift || true
    export INKWELL_BACKEND_URL
    case "$sub" in
      generate)
        inkwell_regenerate_ios_project
        ;;
      sim)
        udid=$(inkwell_ensure_worktree_sim)
        inkwell_boot_sim "$udid"
        echo "$INKWELL_SIM_NAME  $udid"
        ;;
      clean)
        inkwell_teardown_worktree_sim
        ;;
      test|build)
        inkwell_regenerate_ios_project
        udid=$(inkwell_ensure_worktree_sim)
        inkwell_boot_sim "$udid"
        # OfflineSyncUITests needs the real backend reachable (through the
        # black-hole proxy, once it opens up) and running detached, since
        # this command doesn't exit until the test suite does.
        if [ "$sub" = "test" ]; then
          # The black-hole window opens on the proxy's *first* connection, and
          # the app syncs everything unsynced the moment it launches - so a
          # capture left on this device by an earlier run would start that
          # clock before OfflineSyncUITests ever makes its own. Clearing the
          # app's captures (and nothing else - not TCC, not the backend's
          # storage) keeps the window the test's to spend.
          container=$(xcrun simctl get_app_container "$udid" "$INKWELL_BUNDLE_ID" data 2>/dev/null) || container=""
          if [ -n "$container" ] && [ -d "$container/Documents/Inklings" ]; then
            capture_count=$(find "$container/Documents/Inklings" -type f | wc -l | tr -d ' ')
            echo "inkwell: clearing $capture_count captured inkling(s) from $INKWELL_SIM_NAME before OfflineSyncUITests runs" >&2
            rm -rf "$container/Documents/Inklings"
          fi
          mkdir -p "$INKWELL_STORAGE_DIR"
          docker compose up -d --build
          export INKWELL_TEST_PROXY_URL
          if command -v go >/dev/null 2>&1; then
            # Built and run directly rather than `go run`: `go run` never
            # forwards SIGTERM to the binary it compiled, so $! would be the
            # wrapper and the trap below would orphan the proxy on the port.
            proxy_bin="${TMPDIR:-/tmp}/inkwell-blackhole-proxy-$INKWELL_PROJECT_NAME"
            if [ ! -x "$proxy_bin" ] || [ "$INKWELL_WORKTREE/tools/blackhole-proxy/main.go" -nt "$proxy_bin" ]; then
              go build -o "$proxy_bin" "$INKWELL_WORKTREE/tools/blackhole-proxy/main.go"
            fi
            "$proxy_bin" \
              -listen "127.0.0.1:$INKWELL_TEST_PROXY_PORT" \
              -upstream "127.0.0.1:$INKWELL_PORT" \
              -hold-for 15s &
            proxy_pid=$!
            trap 'kill $proxy_pid 2>/dev/null || true' EXIT INT TERM
          else
            echo "inkwell: go not found - OfflineSyncUITests' black-hole proxy won't be available" >&2
          fi
        fi
        xcodebuild "$sub" \
          -project ios/Inkwell.xcodeproj \
          -scheme Inkwell \
          -destination "id=$udid" \
          -derivedDataPath "$INKWELL_DERIVED_DATA" \
          "$@"
        ;;
      *)
        echo "inkwell: unknown ios subcommand '$sub' (generate|sim|test|build|clean)" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "inkwell: unknown command '$cmd' (up|down|ps|logs|info|ios)" >&2
    exit 1
    ;;
esac
