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
#   ./dev.sh up -d        same, all the way to the app on screen, but the
#                         backend is left running in the background and the
#                         command returns instead of holding the terminal
#                         (`--detach`/`--wait` too - they're compose's flags)
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
# actually answering yet. Bounded generously rather than tightly: the very
# first run pulls a base image and builds the backend image, which routinely
# takes minutes. What keeps that from being a long stall when something is
# actually wrong is the liveness check the caller passes in ("$@", run as a
# command) - once it says the backend is gone, it's never arriving and
# there's nothing left to wait for.
#
# The bound is wall-clock, not attempts: an attempt costs anything from
# instant to the curl timeouts above, so counting them would let the real
# wait run many times longer than the number the give-up message reports.
inkwell_wait_for_backend() {
  local start=$SECONDS elapsed=0
  local -a is_alive=("$@")
  while [ "$elapsed" -lt 600 ]; do
    curl -fsS --connect-timeout 2 --max-time 5 -o /dev/null "$INKWELL_BACKEND_URL/inklings" 2>/dev/null && return 0
    if ! "${is_alive[@]}"; then
      echo "inkwell: the backend exited before it became reachable" >&2
      return 1
    fi
    sleep 1
    elapsed=$((SECONDS - start))
  done
  echo "inkwell: gave up waiting for the backend after ${elapsed}s" >&2
  return 1
}

# The two liveness checks a caller can pass. Which one is right depends on
# how compose was started: the foreground form has a compose process of its
# own to watch, while the detached form's compose has already exited on
# purpose, so the containers themselves are all that's left to ask.
inkwell_compose_pid_alive() {
  kill -0 "$1" 2>/dev/null
}

inkwell_compose_containers_alive() {
  [ -n "$(docker compose ps --status running --status restarting --quiet 2>/dev/null)" ]
}

# `-d`/`--detach` (and `--wait`, which implies it) are compose's flags, not
# this script's, so they arrive inside the passthrough args - and they change
# the shape of everything after them: compose returns as soon as the
# containers are up instead of staying in the foreground, so there is no
# process to background, signal, or wait on.
inkwell_args_request_detach() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --) return 1 ;;
      --detach|--detach=true|--detach=1|--wait) return 0 ;;
      -[!-]*)
        case "$arg" in
          *d*) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

inkwell_launch_when_backend_ready() {
  local udid=$1
  shift
  if inkwell_wait_for_backend "$@"; then
    inkwell_build_install_launch "$udid" || true
  else
    echo "inkwell: backend not reachable - skipping app build, install, and launch" >&2
  fi
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
  if ! xcrun simctl install "$udid" "$app_path"; then
    echo "inkwell: installing Inkwell on $INKWELL_SIM_NAME failed - not launching" >&2
    return 1
  fi
  # -CurrentDeviceUDID is read once, at Simulator.app's own launch, so this
  # brings up this worktree's device rather than whichever one was last used
  # - on a cold start. That's as far as it goes: when another lane already
  # has Simulator.app open, macOS activates that instance and discards the
  # flag, and `open -n` does not buy a second one (Simulator is effectively
  # single-instance - verified on Xcode 16.4: -n returns 0 and no new
  # process appears). This worktree's device still gets its own window
  # there, and the app still launches on it; it just may not be frontmost.
  open -a Simulator --args -CurrentDeviceUDID "$udid" || true
  # Without --terminate-running-process, a copy left running by an earlier
  # ./dev.sh is merely brought to the front: the bundle on disk would be the
  # build just installed while the pixels on screen are still the previous one.
  if ! xcrun simctl launch --terminate-running-process "$udid" "$INKWELL_BUNDLE_ID" >/dev/null; then
    echo "inkwell: launching Inkwell on $INKWELL_SIM_NAME failed" >&2
    return 1
  fi
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

    if inkwell_args_request_detach "$@"; then
      # Nothing to background: compose exits on its own the moment the
      # containers are up, and they keep running without this script. The app
      # still gets built, installed, and launched - `up -d` differs in who
      # holds the backend open, not in what the command is for.
      docker compose up --build "$@"
      if [ "$ios_ready" -eq 1 ]; then
        inkwell_launch_when_backend_ready "$udid" inkwell_compose_containers_alive
      fi
      exit 0
    fi

    # Backgrounded rather than exec'd, so there's a point after the backend
    # starts to build/install/launch the app. That costs the plain signal
    # path: bash sets SIGINT to ignored for asynchronous commands in a script,
    # so Ctrl-C only still reaches compose because compose re-arms SIGINT
    # itself - not something this script controls. The trap is therefore
    # load-bearing, not belt-and-suspenders. It also waits for the teardown it
    # started: a signal makes the `wait` below return immediately, so without
    # waiting here the prompt comes back while containers are still stopping
    # and the next ./dev.sh races the leftovers over the same project.
    #
    # A real terminal Ctrl-C sends SIGINT to the whole foreground process
    # group, so compose gets SIGINT directly *and* this trap sends it a
    # second, different signal (SIGTERM) moments later - two signals where
    # the old `exec` form delivered exactly one. Verified this doesn't
    # escalate compose's "press Ctrl+C again to force" behavior: that
    # escalation is keyed to a second SIGINT specifically, not any second
    # signal - confirmed with docker compose v5.0.1 by comparing a
    # single-SIGINT stop against a SIGINT-immediately-followed-by-SIGTERM
    # stop against a container with a 6s SIGTERM trap; both ran the full
    # grace period and exited identically. Safe as written.
    docker compose up --build "$@" &
    compose_pid=$!
    trap 'trap - INT TERM; kill "$compose_pid" 2>/dev/null || true; wait "$compose_pid" 2>/dev/null || true; exit 130' INT TERM

    if [ "$ios_ready" -eq 1 ]; then
      inkwell_launch_when_backend_ready "$udid" inkwell_compose_pid_alive "$compose_pid"
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
            # One inkling is a .json plus, when it was a voice capture, a
            # sibling .m4a - counting every file would report double.
            capture_count=$(find "$container/Documents/Inklings" -type f -name '*.json' | wc -l | tr -d ' ')
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
