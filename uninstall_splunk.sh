#!/usr/bin/env bash
set -euo pipefail

: "${SPLUNK_HOME:=/opt/splunk}"
: "${SPLUNK_USER:=splunk}"
: "${SPLUNK_GROUP:=splunk}"

# Set to true if you want to remove user/group too
: "${REMOVE_USER_GROUP:=false}"

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }

need_root(){
  [[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)."
}

service_name_guess(){
  # Common: splunk.service
  if systemctl list-unit-files 2>/dev/null | grep -q '^splunk\.service'; then
    echo "splunk"
    return
  fi

  # Fallback: any splunk*.service
  local s
  s="$(systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -E '^splunk.*\.service$' | head -n 1 || true)"
  if [[ -n "$s" ]]; then
    echo "${s%.service}"
  else
    echo "splunk"
  fi
}

stop_splunk(){
  if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then
    log "Stopping Splunk via CLI..."
    sudo -u "$SPLUNK_USER" -H "$SPLUNK_HOME/bin/splunk" stop || true
  fi

  local svc
  svc="$(service_name_guess)"

  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
    log "Stopping systemd service: ${svc}"
    systemctl stop "$svc" || true
    log "Disabling systemd service: ${svc}"
    systemctl disable "$svc" || true
  fi

  # Remove common unit file location (best-effort)
  if [[ -f /etc/systemd/system/splunk.service ]]; then
    log "Removing /etc/systemd/system/splunk.service"
    rm -f /etc/systemd/system/splunk.service
  fi

  systemctl daemon-reload || true
  systemctl reset-failed || true
}

remove_files(){
  if [[ -d "$SPLUNK_HOME" ]]; then
    log "Removing Splunk directory: $SPLUNK_HOME"
    rm -rf "$SPLUNK_HOME"
  else
    warn "Splunk directory not found: $SPLUNK_HOME (skipping)"
  fi
}

remove_user_group(){
  [[ "$REMOVE_USER_GROUP" == "true" ]] || { warn "REMOVE_USER_GROUP=false (keeping user/group)."; return; }

  if id "$SPLUNK_USER" >/dev/null 2>&1; then
    log "Removing user: $SPLUNK_USER"
    userdel "$SPLUNK_USER" || true
  fi

  if getent group "$SPLUNK_GROUP" >/dev/null 2>&1; then
    log "Removing group: $SPLUNK_GROUP"
    groupdel "$SPLUNK_GROUP" || true
  fi
}

main(){
  need_root
  stop_splunk
  remove_files
  remove_user_group
  log "Uninstall complete."
  log "Reminder: remove firewall rules for 8000/8089/9997 if you added any."
}

main "$@"
