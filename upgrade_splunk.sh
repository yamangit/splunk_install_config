#!/usr/bin/env bash
set -euo pipefail

: "${SPLUNK_HOME:=/opt/splunk}"
: "${SPLUNK_USER:=splunk}"
: "${SPLUNK_GROUP:=splunk}"

# Provide one:
: "${NEW_SPLUNK_TGZ:=}"
: "${NEW_SPLUNK_TGZ_URL:=}"

log(){ echo "[+] $*"; }
die(){ echo "[x] $*" >&2; exit 1; }

need_root(){ [[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)."; }

fetch(){
  if [[ -n "$NEW_SPLUNK_TGZ" ]]; then
    [[ -f "$NEW_SPLUNK_TGZ" ]] || die "NEW_SPLUNK_TGZ not found: $NEW_SPLUNK_TGZ"
    return
  fi

  [[ -n "$NEW_SPLUNK_TGZ_URL" ]] || die "Provide NEW_SPLUNK_TGZ=/path/to/new.tgz OR NEW_SPLUNK_TGZ_URL=https://..."
  local out=/tmp/new_splunk_enterprise.tgz

  log "Downloading new Splunk tgz..."
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 10 -o "$out" "$NEW_SPLUNK_TGZ_URL"
  else
    wget -O "$out" "$NEW_SPLUNK_TGZ_URL"
  fi
  NEW_SPLUNK_TGZ="$out"
}

backup_recommended(){
  local bk="/tmp/splunk_backup_$(date +%F_%H%M%S).tgz"
  log "Creating backup: $bk"
  tar -czf "$bk" "$SPLUNK_HOME/etc" "$SPLUNK_HOME/var"
  log "Backup created: $bk"
}

main(){
  need_root
  fetch

  [[ -x "$SPLUNK_HOME/bin/splunk" ]] || die "Splunk not found at $SPLUNK_HOME"

  backup_recommended

  log "Stopping Splunk..."
  sudo -u "$SPLUNK_USER" -H "$SPLUNK_HOME/bin/splunk" stop || true

  log "Upgrading: extracting new tgz over existing install..."
  # tgz contains top-level 'splunk' directory => extract to parent of SPLUNK_HOME
  tar -xzf "$NEW_SPLUNK_TGZ" -C "$(dirname "$SPLUNK_HOME")"

  log "Fixing ownership..."
  chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$SPLUNK_HOME"

  log "Starting Splunk after upgrade..."
  sudo -u "$SPLUNK_USER" -H "$SPLUNK_HOME/bin/splunk" start --accept-license --answer-yes --no-prompt

  log "Upgrade complete."
  log "Validate:"
  log "  systemctl status splunk"
  log "  $SPLUNK_HOME/bin/splunk version"
  log "  $SPLUNK_HOME/bin/splunk list search-server   (if search head)"
}

main "$@"
