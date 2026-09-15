#!/usr/bin/env bash
# Entrypoint for the RuneScape: Dragonwilds dedicated server container.
# Runs as root only long enough to fix permissions; the server itself runs as "steam".
set -uo pipefail

APP_ID=4019830
DATA_DIR=/data
SERVER_DIR="$DATA_DIR/server"
BACKUP_DIR="$DATA_DIR/backups"
SAVED_DIR="$SERVER_DIR/RSDragonwilds/Saved"
CONFIG_DIR="$SAVED_DIR/Config/LinuxServer"
CONFIG_FILE="$CONFIG_DIR/DedicatedServer.ini"
SAVES_DIR="$SAVED_DIR/SaveGames"
LOG_FILE="$SAVED_DIR/Logs/RSDragonwilds.log"
SERVER_EXEC="$SERVER_DIR/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"
STEAMCMD=/home/steam/steamcmd/steamcmd.sh

SERVER_PID=""
BACKUP_PID=""
SHUTTING_DOWN=false

log()  { printf '[%s] [dragonwilds] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- permissions
setup_user() {
  log "Setting steam user to UID=${PUID} GID=${PGID}"
  groupmod -o -g "$PGID" steam
  usermod  -o -u "$PUID" -g "$PGID" steam

  mkdir -p "$SERVER_DIR" "$BACKUP_DIR"

  # Full recursive chown of a 10 GB game tree is slow on Unraid's FUSE share,
  # so only do it when the top-level ownership is actually wrong.
  for d in "$DATA_DIR" "$SERVER_DIR" "$BACKUP_DIR" /home/steam; do
    if [ "$(stat -c '%u:%g' "$d")" != "${PUID}:${PGID}" ]; then
      log "Fixing ownership of $d (this can take a while on first run)"
      chown -R "$PUID:$PGID" "$d"
    fi
  done
}

# ---------------------------------------------------------------- install / update
update_server() {
  local validate=""
  [ "${VALIDATE_ON_START,,}" = "true" ] && validate="validate"

  log "Checking for server updates via SteamCMD (AppID $APP_ID)"
  local attempt
  for attempt in 1 2 3; do
    if gosu steam "$STEAMCMD" \
        +@sSteamCmdForcePlatformType linux \
        +force_install_dir "$SERVER_DIR" \
        +login anonymous \
        +app_update "$APP_ID" $validate \
        +quit; then
      log "SteamCMD finished successfully"
      return 0
    fi
    # An identical retry cannot clear a stuck install state: SteamCMD reports
    # "state is 0x6 after update job" and moves zero bytes every time. Adding
    # validation re-checksums the install and pulls what the stale manifest
    # was hiding, so escalate to it for the remaining attempts.
    if [ -z "$validate" ]; then
      log "SteamCMD failed (attempt $attempt/3); retrying with validation in 10s"
      validate="validate"
    else
      log "SteamCMD failed (attempt $attempt/3), retrying in 10s"
    fi
    sleep 10
  done
  log "WARNING: SteamCMD failed 3 times; continuing with existing files if present"
  return 1
}

# Steam records install state in the app manifest. Bit 0x2 means an update is
# still required, i.e. the files on disk are an older build than the live one.
# Clients on the patched build cannot join such a server, so say so plainly
# rather than letting it look healthy.
warn_if_update_pending() {
  local manifest="$SERVER_DIR/steamapps/appmanifest_${APP_ID}.acf"
  [ -f "$manifest" ] || return 0

  local flags
  flags=$(sed -n 's/.*"StateFlags"[^"]*"\([0-9]*\)".*/\1/p' "$manifest" | head -1)
  [ -n "$flags" ] || return 0

  if [ $(( flags & 2 )) -ne 0 ]; then
    log "WARNING: Steam still reports an update as required (StateFlags=${flags})."
    log "WARNING: This server is running an older build; patched clients cannot join."
    log "WARNING: Set VALIDATE_ON_START=true and restart the container to repair it."
  fi
}

# ---------------------------------------------------------------- config
write_config() {
  # The game keeps its instance lock, logs, crash dumps and save games under
  # Saved/. If any of that tree is root-owned the server cannot create its
  # lock file and aborts with "Multiple instances of the game detected".
  # The tree is small, so a recursive chown on every start is cheap.
  mkdir -p "$CONFIG_DIR"
  chown -R "$PUID:$PGID" "$SAVED_DIR"

  # Preserve the server's identity across restarts if the game has written one.
  local guid=""
  if [ -f "$CONFIG_FILE" ]; then
    guid=$(grep -m1 '^ServerGuid=' "$CONFIG_FILE" | cut -d= -f2- || true)
  fi

  log "Writing $CONFIG_FILE"
  cat > "$CONFIG_FILE" <<EOF
[SectionsToSave]
bCanSaveAllSections=true

[/Script/Dominion.DedicatedServerSettings]
OwnerId=${OWNER_ID}
AdminPassword=${ADMIN_PASSWORD}
WorldPassword=${WORLD_PASSWORD}
ServerName=${SERVER_NAME}
DefaultWorldName=${DEFAULT_WORLD_NAME}
ServerGuid=${guid}
EOF
  chown "$PUID:$PGID" "$CONFIG_FILE"
}

# ---------------------------------------------------------------- backups
do_backup() {
  [ -d "$SAVES_DIR" ] || return 0
  [ -n "$(ls -A "$SAVES_DIR" 2>/dev/null)" ] || return 0

  local ts file
  ts=$(date '+%Y%m%d-%H%M%S')
  file="$BACKUP_DIR/saves-$ts.tar.gz"
  if gosu steam tar -czf "$file" -C "$SAVED_DIR" SaveGames 2>/dev/null; then
    log "Backup written: $(basename "$file")"
  else
    log "WARNING: backup failed"
    return 1
  fi

  # Prune to the newest BACKUP_KEEP files
  if [ "${BACKUP_KEEP:-0}" -gt 0 ]; then
    ls -1t "$BACKUP_DIR"/saves-*.tar.gz 2>/dev/null \
      | tail -n +"$((BACKUP_KEEP + 1))" \
      | xargs -r rm -f
  fi
}

backup_loop() {
  while true; do
    sleep "$((BACKUP_INTERVAL * 60))"
    do_backup
  done
}

# ---------------------------------------------------------------- server control
# Returns 0 if something inside the container already has UDP $1 bound.
udp_port_in_use() {
  local hex
  hex=$(printf '%04X' "$1")
  grep -qiE "^ *[0-9]+: [0-9A-F]+:${hex} " /proc/net/udp /proc/net/udp6 2>/dev/null
}

check_port_free() {
  udp_port_in_use "$SERVER_PORT" || return 0
  log "ERROR: UDP port ${SERVER_PORT} is already bound inside the container, so the game cannot use it."
  if [ -n "${PORT:-}" ]; then
    log "ERROR: A PORT variable is set (PORT=${PORT}). Tailscale's daemon reads PORT as its own listen port,"
    log "ERROR: so with Unraid's Tailscale integration enabled it grabs the game port first."
    log "ERROR: Remove the PORT variable from the container and use SERVER_PORT instead."
  fi
  die "game port ${SERVER_PORT}/udp unavailable"
}

start_server() {
  local args=(-log "-Port=${SERVER_PORT}")
  if [ -n "${MAX_PLAYERS}" ]; then
    args+=("-ini:Game:[/Script/Engine.GameSession]:MaxPlayers=${MAX_PLAYERS}")
  fi
  # shellcheck disable=SC2206
  [ -n "${EXTRA_ARGS}" ] && args+=(${EXTRA_ARGS})

  log "Starting server: name='${SERVER_NAME}' world='${DEFAULT_WORLD_NAME}' port=${SERVER_PORT}/udp"
  cd "$SERVER_DIR" || die "cannot cd to $SERVER_DIR"
  gosu steam "$SERVER_EXEC" "${args[@]}" &
  SERVER_PID=$!
  log "Server PID $SERVER_PID"
}

stop_server() {
  [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null || return 0
  log "Sending SIGTERM to server (waiting up to ${STOP_TIMEOUT}s)"
  kill -TERM "$SERVER_PID" 2>/dev/null
  local i=0
  while kill -0 "$SERVER_PID" 2>/dev/null && [ "$i" -lt "$STOP_TIMEOUT" ]; do
    sleep 1; i=$((i + 1))
  done
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    log "Server did not exit in time, sending SIGKILL"
    kill -KILL "$SERVER_PID" 2>/dev/null
  fi
  wait "$SERVER_PID" 2>/dev/null
  log "Server stopped"
}

on_term() {
  SHUTTING_DOWN=true
  log "Shutdown requested"
  [ -n "$BACKUP_PID" ] && kill "$BACKUP_PID" 2>/dev/null
  stop_server
  [ "${BACKUP_ON_STOP,,}" = "true" ] && do_backup
  exit 0
}

# ================================================================ main
log "RuneScape: Dragonwilds Dedicated Server container starting"
log "TZ=${TZ}"

[ -n "${OWNER_ID}" ]       || die "OWNER_ID is required. Find your Player ID at the bottom of the in-game Settings menu."
[ -n "${ADMIN_PASSWORD}" ] || die "ADMIN_PASSWORD is required."

# PORT was the original name of this setting. It is honoured for old container
# configs, but it collides with Tailscale (tailscaled uses PORT as its own
# listen port), so SERVER_PORT is the supported name.
if [ -z "${SERVER_PORT:-}" ] && [ -n "${PORT:-}" ]; then
  log "WARNING: PORT is deprecated and conflicts with Tailscale; rename it to SERVER_PORT"
  SERVER_PORT="$PORT"
fi
SERVER_PORT="${SERVER_PORT:-7777}"

setup_user

if [ "${UPDATE_ON_START,,}" = "true" ] || [ ! -x "$SERVER_EXEC" ]; then
  update_server || warn_if_update_pending
else
  log "UPDATE_ON_START=false, skipping SteamCMD"
fi

[ -f "$SERVER_EXEC" ] || die "Server executable not found at $SERVER_EXEC. Check SteamCMD output above."
chmod +x "$SERVER_EXEC"
chmod +x "$SERVER_DIR/RSDragonwilds/Plugins/Developer/Sentry/Binaries/Linux/crashpad_handler" 2>/dev/null || true

write_config

trap on_term TERM INT

if [ "${BACKUP_INTERVAL:-0}" -gt 0 ]; then
  log "Save backups every ${BACKUP_INTERVAL} min, keeping ${BACKUP_KEEP} (-> $BACKUP_DIR)"
  backup_loop &
  BACKUP_PID=$!
fi

# Main run loop with optional crash restart
while true; do
  check_port_free
  start_server
  wait "$SERVER_PID"
  code=$?
  [ "$SHUTTING_DOWN" = true ] && exit 0
  log "Server exited with code $code"
  if [ "${AUTO_RESTART,,}" = "true" ]; then
    log "AUTO_RESTART=true, restarting in 10s"
    sleep 10
  else
    [ -n "$BACKUP_PID" ] && kill "$BACKUP_PID" 2>/dev/null
    exit "$code"
  fi
done
