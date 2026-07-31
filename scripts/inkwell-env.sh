# Shared by dev.sh: derives everything that has to be unique per worktree
# (compose project name, published port, storage path, simulator name) from
# the worktree's own filesystem path, so two lanes running this repo at once
# can never collide - see docs/runtime-isolation.md. Sourced, not executed.

INKWELL_BUNDLE_ID="com.inkwell.app"
INKWELL_TEMPLATE_SIM_NAME="InkwellSimTemplate"
INKWELL_SIM_DEVICETYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-16"

inkwell_worktree_root() {
  git rev-parse --show-toplevel
}

# Sets INKWELL_* (and COMPOSE_PROJECT_NAME) for the current worktree.
# INKWELL_PORT is only a *candidate* here - inkwell_free_port below is what
# actually guarantees it's collision-free.
inkwell_derive() {
  local worktree hash_full base_port
  worktree=$(inkwell_worktree_root) || { echo "inkwell: not inside a git worktree" >&2; return 1; }
  hash_full=$(printf '%s' "$worktree" | shasum -a 256 | cut -d' ' -f1)

  INKWELL_WORKTREE="$worktree"
  INKWELL_PROJECT_NAME="inkwell-${hash_full:0:12}"
  INKWELL_STORAGE_DIR="$worktree/backend/data"
  INKWELL_DERIVED_DATA="$worktree/ios/DerivedData"
  INKWELL_SIM_NAME="Inkwell-${hash_full:0:12}"

  base_port=$((16#${hash_full:0:8} % 10000 + 20000))
  INKWELL_PORT=$(inkwell_free_port "$base_port" "$worktree") || return 1
  INKWELL_BACKEND_URL="http://127.0.0.1:${INKWELL_PORT}"

  export INKWELL_WORKTREE INKWELL_PROJECT_NAME INKWELL_STORAGE_DIR \
    INKWELL_DERIVED_DATA INKWELL_SIM_NAME INKWELL_PORT INKWELL_BACKEND_URL
  export COMPOSE_PROJECT_NAME="$INKWELL_PROJECT_NAME"
}

# Starts scanning at $1 and walks forward until it finds a port nothing is
# listening on, OR a port already held by *this worktree's own* backend
# container (so restarting a lane doesn't bounce it to a new port every
# time). This is the actual collision guarantee: the hash makes collisions
# unlikely, this makes them structurally impossible to land on.
inkwell_free_port() {
  local candidate=$1 worktree=$2 attempts=0 owner
  while [ $attempts -lt 500 ]; do
    if ! nc -z -w1 127.0.0.1 "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
    owner=$(docker ps --filter "label=com.inkwell.worktree=$worktree" \
      --filter "label=com.inkwell.port=$candidate" -q 2>/dev/null)
    if [ -n "$owner" ]; then
      echo "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
    attempts=$((attempts + 1))
  done
  echo "inkwell: could not find a free port starting at $1" >&2
  return 1
}

inkwell_find_sim_udid() {
  xcrun simctl list devices available 2>/dev/null | grep -F "    $1 (" | head -1 \
    | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/'
}

inkwell_latest_ios_runtime() {
  xcrun simctl list runtimes available 2>/dev/null | grep '^iOS ' | tail -1 \
    | sed -E 's/.*(com\.apple\.CoreSimulator\.SimRuntime\.[^ )]+).*/\1/'
}

# Machine-wide, so it needs a machine-wide lock: the template is created by
# whichever worktree gets there first, and a second worktree racing it would
# otherwise find the device mid-setup and clone it while it's still booted
# (clone requires a shutdown device) or before the grants land. Held across
# the whole find-or-create block, not just the create.
INKWELL_TEMPLATE_LOCK="${TMPDIR:-/tmp}/inkwell-sim-template.lock"

inkwell_acquire_template_lock() {
  local waited=0 holder
  while ! mkdir "$INKWELL_TEMPLATE_LOCK" 2>/dev/null; do
    if [ "$waited" -eq 0 ]; then
      echo "inkwell: waiting for another worktree to finish preparing the simulator template" >&2
    fi
    # Only after a grace period, so this can't mistake the split second
    # between mkdir and the pid write for an abandoned lock.
    if [ "$waited" -ge 10 ]; then
      holder=$(cat "$INKWELL_TEMPLATE_LOCK/pid" 2>/dev/null || true)
      if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
        echo "inkwell: reclaiming stale simulator template lock ($INKWELL_TEMPLATE_LOCK)" >&2
        rm -rf "$INKWELL_TEMPLATE_LOCK"
        continue
      fi
    fi
    if [ "$waited" -ge 900 ]; then
      echo "inkwell: timed out waiting for the simulator template lock ($INKWELL_TEMPLATE_LOCK)" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo $$ >"$INKWELL_TEMPLATE_LOCK/pid"
}

# One-time, machine-wide: a simulator with the mic + speech-recognition
# grants already applied (the latter needs the direct TCC.db edit noted in
# AGENTS.md - simctl privacy has no speech-recognition service). Every
# per-worktree simulator is cloned from this one, and simctl clone carries
# the TCC.db over, so no worktree ever repeats the manual grant step.
inkwell_ensure_template_sim() {
  local udid rc=0
  inkwell_acquire_template_lock || return 1
  udid=$(inkwell_create_template_sim) || rc=$?
  rm -rf "$INKWELL_TEMPLATE_LOCK"
  [ "$rc" -eq 0 ] || return "$rc"
  echo "$udid"
}

# Every step is checked and the grant is read back before this device is
# allowed to exist under the template name: it's cached by name forever
# afterwards, so a half-configured one would silently propagate a missing
# grant into every worktree's clone. On any failure the device is deleted,
# leaving the next run to start clean.
inkwell_create_template_sim() {
  local udid runtime tcc_db granted=""
  udid=$(inkwell_find_sim_udid "$INKWELL_TEMPLATE_SIM_NAME")
  if [ -n "$udid" ]; then
    echo "$udid"
    return 0
  fi

  runtime=$(inkwell_latest_ios_runtime)
  if [ -z "$runtime" ]; then
    echo "inkwell: no available iOS simulator runtime found" >&2
    return 1
  fi

  echo "inkwell: creating simulator template (one-time; grants mic + speech recognition)" >&2
  udid=$(xcrun simctl create "$INKWELL_TEMPLATE_SIM_NAME" "$INKWELL_SIM_DEVICETYPE" "$runtime") || return 1

  tcc_db="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/TCC/TCC.db"
  if xcrun simctl boot "$udid" >&2 \
    && xcrun simctl bootstatus "$udid" -b >/dev/null \
    && xcrun simctl privacy "$udid" grant microphone "$INKWELL_BUNDLE_ID" >&2 \
    && xcrun simctl shutdown "$udid" >&2 \
    && sqlite3 "$tcc_db" \
      "INSERT OR IGNORE INTO access (service,client,client_type,auth_value,auth_reason,auth_version) VALUES ('kTCCServiceSpeechRecognition','$INKWELL_BUNDLE_ID',0,2,3,1);" >&2; then
    granted=$(sqlite3 "$tcc_db" \
      "SELECT auth_value FROM access WHERE service='kTCCServiceSpeechRecognition' AND client='$INKWELL_BUNDLE_ID';" 2>/dev/null)
  fi

  if [ "$granted" != "2" ]; then
    echo "inkwell: simulator template setup failed - mic/speech-recognition grants did not land, deleting the half-configured device" >&2
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    return 1
  fi

  echo "$udid"
}

# Finds (or clones from the template) this worktree's own simulator device.
# Stable across restarts because the name is derived from the worktree hash,
# same as the port and compose project name.
inkwell_ensure_worktree_sim() {
  local udid template_udid
  udid=$(inkwell_find_sim_udid "$INKWELL_SIM_NAME")
  if [ -n "$udid" ]; then
    echo "$udid"
    return 0
  fi

  template_udid=$(inkwell_ensure_template_sim) || return 1
  echo "inkwell: cloning simulator for this worktree ($INKWELL_SIM_NAME)" >&2
  xcrun simctl clone "$template_udid" "$INKWELL_SIM_NAME"
}

inkwell_boot_sim() {
  local udid=$1
  if ! xcrun simctl list devices | grep -F "$udid" | grep -q "(Booted)"; then
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
  fi
}
