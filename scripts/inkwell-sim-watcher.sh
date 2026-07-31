#!/usr/bin/env bash
# Detached teardown watcher for one worktree's cloned simulator, spawned by
# inkwell_spawn_sim_watcher (scripts/inkwell-env.sh) whenever that simulator
# is booted. A clone costs 1-3GB, so it must not outlive the lane that made
# it: `dev.sh down` covers "the stack came down", and this covers the
# independent case where the device is simply shut down - Simulator.app quit,
# `simctl shutdown`, a reboot of the device - possibly long after the dev.sh
# that started it exited.
#
# Usage: inkwell-sim-watcher.sh <udid> <derived-data-path> <pidfile>
set -uo pipefail

udid=${1:?usage: inkwell-sim-watcher.sh <udid> <derived-data-path> <pidfile>}
derived_data=${2:?}
pidfile=${3:?}

interval=5
arming_timeout=120

# Outlive the invoking dev.sh: nohup covers SIGHUP, and ignoring SIGINT keeps
# a Ctrl-C aimed at `dev.sh ios test` - which this shares a process group with
# - from taking the watcher down too and silently leaking the device.
trap '' HUP INT
trap 'if [ "$(readlink "$pidfile" 2>/dev/null)" = "$$" ]; then rm -f "$pidfile"; fi' EXIT

device_line() {
  xcrun simctl list devices 2>/dev/null | grep -F "($udid)" | head -1
}

# Arms only once the device has actually been seen Booted. The spawn already
# happens after `simctl bootstatus`, so this is insurance rather than the
# normal path - but a watcher that armed on any "not Booted" reading would
# delete the device out from under the run that just created it.
armed=0
waited=0
while :; do
  line=$(device_line)
  # Gone already - `dev.sh down` or `dev.sh ios clean` got here first.
  [ -n "$line" ] || exit 0
  case "$line" in
    *"(Booted)"*)
      armed=1
      ;;
    *)
      [ "$armed" -eq 1 ] && break
      waited=$((waited + interval))
      [ "$waited" -ge "$arming_timeout" ] && exit 0
      ;;
  esac
  sleep "$interval"
done

xcrun simctl delete "$udid" >/dev/null 2>&1 || true
# Guarded because this is an rm -rf of an argument: only ever the DerivedData
# path scripts/inkwell-env.sh derives for a worktree.
case "$derived_data" in
  */ios/DerivedData) rm -rf "$derived_data" ;;
esac
