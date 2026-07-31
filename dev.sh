#!/usr/bin/env bash
# The only documented way to run Inkwell. Every worktree gets its own
# backend port, storage directory, container, and (for iOS) simulator and
# DerivedData path, derived automatically from the worktree's path - see
# docs/runtime-isolation.md for why and scripts/inkwell-env.sh for how.
#
# Usage:
#   ./dev.sh              start the backend stack (same as `up`)
#   ./dev.sh up           start the backend stack in the foreground
#   ./dev.sh down         stop it, and delete this worktree's simulator+DerivedData
#   ./dev.sh info         print this worktree's derived port/storage/etc
#   ./dev.sh ios generate regenerate the Xcode project, backend URL baked in
#   ./dev.sh ios sim      ensure+boot this worktree's simulator, print its UDID
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

cmd="${1:-up}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  up)
    mkdir -p "$INKWELL_STORAGE_DIR"
    echo "inkwell: $INKWELL_PROJECT_NAME -> http://127.0.0.1:$INKWELL_PORT (storage: $INKWELL_STORAGE_DIR)"
    exec docker compose up --build "$@"
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
EOF
    ;;
  ios)
    sub="${1:-generate}"
    [ $# -gt 0 ] && shift || true
    export INKWELL_BACKEND_URL
    case "$sub" in
      generate)
        (cd ios && xcodegen generate)
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
        (cd ios && xcodegen generate)
        udid=$(inkwell_ensure_worktree_sim)
        inkwell_boot_sim "$udid"
        exec xcodebuild "$sub" \
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
