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
# (clone requires a shutdown device) or before the grants land.
#
# The lock is a symlink whose target is the holder's pid: symlink creation
# fails outright when the path exists, and the pid arrives with it, so the
# lock is published complete and there's no instant where another lane can
# see it empty and mistake it for abandoned. (A staging dir renamed into
# place is not equivalent - `mv` moves it *inside* an existing lock and
# reports success, handing every waiter the lock.)
INKWELL_TEMPLATE_LOCK="${TMPDIR:-/tmp}/inkwell-sim-template.lock"

inkwell_acquire_template_lock() {
  local waited=0 holder
  while ! ln -s "$$" "$INKWELL_TEMPLATE_LOCK" 2>/dev/null; do
    if [ -e "$INKWELL_TEMPLATE_LOCK" ] && [ ! -L "$INKWELL_TEMPLATE_LOCK" ]; then
      echo "inkwell: $INKWELL_TEMPLATE_LOCK is not this script's lock - remove it and re-run" >&2
      return 1
    fi
    holder=$(readlink "$INKWELL_TEMPLATE_LOCK" 2>/dev/null) || holder=""
    # Deliberately never reclaimed automatically: two lanes that agree a lock
    # is abandoned both delete it and both proceed, which is the collision the
    # lock exists to prevent. An interrupted run releases it via the trap
    # below, so a lock outliving its holder means SIGKILL - rare enough to be
    # worth one loud, actionable message instead of a silent double holder.
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      echo "inkwell: the simulator template lock is held by pid $holder, which is gone" >&2
      echo "inkwell: remove $INKWELL_TEMPLATE_LOCK and re-run" >&2
      return 1
    fi
    if [ "$waited" -eq 0 ]; then
      echo "inkwell: waiting for another worktree to finish preparing the simulator template" >&2
    fi
    if [ "$waited" -ge 300 ]; then
      echo "inkwell: timed out waiting for the simulator template lock${holder:+ (held by pid $holder)}" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

# Only ever removes a lock this process still owns, so a run whose lock was
# taken from it can't delete its successor's.
inkwell_release_template_lock() {
  local holder
  holder=$(readlink "$INKWELL_TEMPLATE_LOCK" 2>/dev/null) || holder=""
  [ "$holder" = "$$" ] || return 0
  rm -f "$INKWELL_TEMPLATE_LOCK"
}

# Staging devices are inert - nothing ever looks them up by name - so one
# left behind by a hard kill costs disk and nothing else. Only ever called
# while holding the lock, where no other lane can have a staging device in
# flight, so anything matching here is known to be abandoned.
inkwell_sweep_pending_template_sims() {
  local udid
  xcrun simctl list devices 2>/dev/null \
    | grep -F "    ${INKWELL_TEMPLATE_SIM_NAME}-pending-" \
    | sed -nE 's/.*\(([0-9A-F-]+)\).*/\1/p' \
    | while read -r udid; do
        echo "inkwell: deleting an abandoned simulator template staging device ($udid)" >&2
        xcrun simctl delete "$udid" >/dev/null 2>&1 || true
      done || true
}

# A device that was created but not yet verified must not outlive this run:
# it would be cached under the template name and cloned, missing grants and
# all, by every worktree afterwards. Idempotent - the INT and EXIT traps both
# reach it.
inkwell_abandon_template_sim() {
  if [ -n "${INKWELL_TEMPLATE_PENDING:-}" ]; then
    echo "inkwell: interrupted while preparing the simulator template - deleting the unverified device" >&2
    xcrun simctl delete "$INKWELL_TEMPLATE_PENDING" >/dev/null 2>&1 || true
    INKWELL_TEMPLATE_PENDING=""
  fi
  inkwell_release_template_lock
}

# One-time, machine-wide: a simulator with the mic + speech-recognition
# grants already applied (the latter needs the direct TCC.db edit noted in
# AGENTS.md - simctl privacy has no speech-recognition service). Every
# per-worktree simulator is cloned from this one, and simctl clone carries
# the TCC.db over, so no worktree ever repeats the manual grant step.
#
# Checked once before taking the lock and again while holding it, so the
# steady state - template already there, which is every run after the first -
# never touches the lock at all.
inkwell_ensure_template_sim() {
  local udid rc=0

  udid=$(inkwell_find_sim_udid "$INKWELL_TEMPLATE_SIM_NAME") || udid=""
  if [ -n "$udid" ]; then
    echo "$udid"
    return 0
  fi

  inkwell_acquire_template_lock || return 1
  INKWELL_TEMPLATE_PENDING=""
  INKWELL_TEMPLATE_UDID=""
  trap 'inkwell_abandon_template_sim' EXIT
  trap 'inkwell_abandon_template_sim; exit 130' HUP INT TERM

  inkwell_sweep_pending_template_sims
  udid=$(inkwell_find_sim_udid "$INKWELL_TEMPLATE_SIM_NAME") || udid=""
  if [ -z "$udid" ]; then
    if inkwell_create_template_sim; then
      udid="$INKWELL_TEMPLATE_UDID"
    else
      rc=1
    fi
  fi

  trap - EXIT HUP INT TERM
  inkwell_release_template_lock
  [ "$rc" -eq 0 ] || return "$rc"
  echo "$udid"
}

# The template name is the commit point, not the starting point: the device
# is built under a staging name and only renamed once both grants have been
# read back out of its TCC.db. The name is what every later run and every
# worktree clone trusts, so nothing may wear it until it has been proven -
# and unlike the traps above, a rename can't be missed by SIGKILL or a power
# cut, which would otherwise leave an ungranted device answering to the
# template name forever. Publishes the UDID through INKWELL_TEMPLATE_UDID
# rather than stdout so it runs in its caller's shell, where the caller's
# trap can see the in-progress device in INKWELL_TEMPLATE_PENDING.
inkwell_create_template_sim() {
  local udid runtime tcc_db staging grants=""

  runtime=$(inkwell_latest_ios_runtime) || runtime=""
  if [ -z "$runtime" ]; then
    echo "inkwell: no available iOS simulator runtime found" >&2
    return 1
  fi

  staging="${INKWELL_TEMPLATE_SIM_NAME}-pending-$$"
  echo "inkwell: creating simulator template (one-time; grants mic + speech recognition)" >&2
  udid=$(xcrun simctl create "$staging" "$INKWELL_SIM_DEVICETYPE" "$runtime") || return 1
  INKWELL_TEMPLATE_PENDING="$udid"

  tcc_db="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/TCC/TCC.db"
  if xcrun simctl boot "$udid" >&2 \
    && xcrun simctl bootstatus "$udid" -b >/dev/null \
    && xcrun simctl privacy "$udid" grant microphone "$INKWELL_BUNDLE_ID" >&2 \
    && xcrun simctl shutdown "$udid" >&2 \
    && sqlite3 "$tcc_db" \
      "INSERT OR IGNORE INTO access (service,client,client_type,auth_value,auth_reason,auth_version) VALUES ('kTCCServiceSpeechRecognition','$INKWELL_BUNDLE_ID',0,2,3,1);" >&2; then
    grants=$(sqlite3 "$tcc_db" \
      "SELECT COUNT(*) FROM access WHERE client='$INKWELL_BUNDLE_ID' AND auth_value=2 AND service IN ('kTCCServiceMicrophone','kTCCServiceSpeechRecognition');" 2>/dev/null) || grants=""
  fi

  if [ "$grants" != "2" ]; then
    echo "inkwell: simulator template setup failed - mic/speech-recognition grants did not land, deleting the half-configured device" >&2
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    INKWELL_TEMPLATE_PENDING=""
    return 1
  fi

  if ! xcrun simctl rename "$udid" "$INKWELL_TEMPLATE_SIM_NAME" >&2; then
    echo "inkwell: could not name the verified simulator template, deleting it" >&2
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    INKWELL_TEMPLATE_PENDING=""
    return 1
  fi

  INKWELL_TEMPLATE_PENDING=""
  INKWELL_TEMPLATE_UDID="$udid"
}

# Finds (or clones from the template) this worktree's own simulator device.
# Stable across restarts because the name is derived from the worktree hash,
# same as the port and compose project name.
inkwell_ensure_worktree_sim() {
  local udid template_udid
  udid=$(inkwell_find_sim_udid "$INKWELL_SIM_NAME") || udid=""
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
