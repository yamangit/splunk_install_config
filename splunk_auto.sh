#!/usr/bin/env bash
set -euo pipefail

# =========================
# Splunk Install + Configure
# Single + Distributed (Indexer/Search Head)
# RHEL + Debian (tgz-based)
# =========================

# ---- Defaults (override via env vars) ----
: "${SPLUNK_HOME:=/opt/splunk}"
: "${SPLUNK_USER:=splunk}"
: "${SPLUNK_GROUP:=splunk}"
: "${SPLUNK_MGMT_PORT:=8089}"
: "${SPLUNK_WEB_PORT:=8000}"
: "${SPLUNK_RECEIVER_PORT:=9997}"     # forwarders -> indexer
: "${SPLUNK_HEC_PORT:=8088}"          # optional, not enabled by default

# You MUST supply one of these:
: "${SPLUNK_TGZ:=}"                   # local path to splunk-*.tgz
: "${SPLUNK_TGZ_URL:=}"               # URL to splunk-*.tgz (optional)

# Admin credentials (required for config steps)
: "${SPLUNK_ADMIN_USER:=admin}"
: "${SPLUNK_ADMIN_PASS:=}"

# For distributed mode
: "${INDEXER_HOST:=}"                 # indexer mgmt host/IP
: "${INDEXER_MGMT_PORT:=$SPLUNK_MGMT_PORT}"
: "${INDEXER_ADMIN_USER:=$SPLUNK_ADMIN_USER}"
: "${INDEXER_ADMIN_PASS:=}"           # indexer admin pass (can be same as SPLUNK_ADMIN_PASS)

# Optional: set a fixed servername for Splunk
: "${SPLUNK_SERVER_NAME:=}"

log() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die() { echo "[x] $*" >&2; exit 1; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Run as root (or with sudo)."
  fi
}

detect_os_family() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    local id_like="${ID_LIKE:-}"
    local id="${ID:-}"
    if echo "$id_like $id" | grep -qiE '(rhel|fedora|centos|rocky|almalinux)'; then
      echo "rhel"
      return
    fi
    if echo "$id_like $id" | grep -qiE '(debian|ubuntu)'; then
      echo "debian"
      return
    fi
  fi
  # fallback
  if command -v apt-get >/dev/null 2>&1; then echo "debian"; return; fi
  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then echo "rhel"; return; fi
  die "Could not detect OS family."
}

install_deps() {
  local fam; fam="$(detect_os_family)"
  log "Detected OS family: $fam"

  if [[ "$fam" == "debian" ]]; then
    log "Installing dependencies (Debian-based)..."
    apt-get update -y
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget tar gzip procps net-tools sudo
  else
    log "Installing dependencies (RHEL-based)..."
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y ca-certificates curl wget tar gzip procps-ng net-tools sudo
    else
      yum install -y ca-certificates curl wget tar gzip procps-ng net-tools sudo
    fi
  fi
}

ensure_user_group() {
  if ! getent group "$SPLUNK_GROUP" >/dev/null; then
    log "Creating group: $SPLUNK_GROUP"
    groupadd --system "$SPLUNK_GROUP"
  fi
  if ! id "$SPLUNK_USER" >/dev/null 2>&1; then
    log "Creating user: $SPLUNK_USER"
    useradd --system --home-dir "$SPLUNK_HOME" --shell /bin/bash --gid "$SPLUNK_GROUP" "$SPLUNK_USER"
  fi
}

fetch_tgz_if_needed() {
  if [[ -n "$SPLUNK_TGZ" ]]; then
    [[ -f "$SPLUNK_TGZ" ]] || die "SPLUNK_TGZ not found: $SPLUNK_TGZ"
    return
  fi

  [[ -n "$SPLUNK_TGZ_URL" ]] || die "Provide SPLUNK_TGZ=/path/to/splunk.tgz OR SPLUNK_TGZ_URL=https://..."
  local out="/tmp/splunk_enterprise.tgz"

  log "Downloading Splunk tgz..."
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 10 -o "$out" "$SPLUNK_TGZ_URL"
  else
    wget -O "$out" "$SPLUNK_TGZ_URL"
  fi
  SPLUNK_TGZ="$out"
  log "Downloaded to: $SPLUNK_TGZ"
}

extract_splunk() {
  if [[ -d "$SPLUNK_HOME/bin" ]]; then
    warn "Splunk appears installed already at $SPLUNK_HOME (bin exists). Skipping extract."
    return
  fi

  log "Extracting Splunk to $(dirname "$SPLUNK_HOME") ..."
  mkdir -p "$(dirname "$SPLUNK_HOME")"
  tar -xzf "$SPLUNK_TGZ" -C "$(dirname "$SPLUNK_HOME")"

  [[ -d "$SPLUNK_HOME" ]] || die "Extraction failed: $SPLUNK_HOME not found after extract."
  chown -R "$SPLUNK_USER:$SPLUNK_GROUP" "$SPLUNK_HOME"
}

write_user_seed() {
  [[ -n "$SPLUNK_ADMIN_PASS" ]] || die "SPLUNK_ADMIN_PASS is required."
  log "Writing admin seed credentials..."
  install -d -m 0750 -o "$SPLUNK_USER" -g "$SPLUNK_GROUP" "$SPLUNK_HOME/etc/system/local"
  cat >"$SPLUNK_HOME/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = $SPLUNK_ADMIN_USER
PASSWORD = $SPLUNK_ADMIN_PASS
EOF
  chown "$SPLUNK_USER:$SPLUNK_GROUP" "$SPLUNK_HOME/etc/system/local/user-seed.conf"
  chmod 0640 "$SPLUNK_HOME/etc/system/local/user-seed.conf"
}

set_servername_if_provided() {
  if [[ -n "$SPLUNK_SERVER_NAME" ]]; then
    log "Setting serverName: $SPLUNK_SERVER_NAME"
    install -d -m 0750 -o "$SPLUNK_USER" -g "$SPLUNK_GROUP" "$SPLUNK_HOME/etc/system/local"
    cat >"$SPLUNK_HOME/etc/system/local/server.conf" <<EOF
[general]
serverName = $SPLUNK_SERVER_NAME
EOF
    chown "$SPLUNK_USER:$SPLUNK_GROUP" "$SPLUNK_HOME/etc/system/local/server.conf"
    chmod 0640 "$SPLUNK_HOME/etc/system/local/server.conf"
  fi
}

splunk_cmd() {
  # run as splunk user
  sudo -u "$SPLUNK_USER" -H "$SPLUNK_HOME/bin/splunk" "$@"
}

first_start_and_enable_boot() {
  log "Starting Splunk first time (accept license)..."
  splunk_cmd start --accept-license --answer-yes --no-prompt

  log "Enabling boot-start (systemd)..."
  "$SPLUNK_HOME/bin/splunk" enable boot-start -user "$SPLUNK_USER" --accept-license --answer-yes --no-prompt

  log "Restarting Splunk to ensure services are correct..."
  splunk_cmd restart
}

configure_common_ports() {
  # Ensure mgmt and web ports can be set if desired. Splunk defaults are fine; keep minimal.
  # You can extend this with `splunk set web-port`, etc.
  :
}

# -------------------------
# Mode: Single Instance
# -------------------------
configure_single() {
  log "Configuring SINGLE instance mode..."
  # Nothing special needed beyond install/start.
  log "Single instance ready."
  log "Web:  http://<host>:$SPLUNK_WEB_PORT   (default 8000)"
  log "Mgmt: https://<host>:$SPLUNK_MGMT_PORT (default 8089)"
}

# -------------------------
# Mode: Indexer
# -------------------------
configure_indexer() {
  log "Configuring INDEXER..."

  # Enable receiving on 9997 for forwarders
  log "Enabling receiver on port $SPLUNK_RECEIVER_PORT ..."
  splunk_cmd enable listen "$SPLUNK_RECEIVER_PORT" -auth "$SPLUNK_ADMIN_USER:$SPLUNK_ADMIN_PASS"
  
  # Disable Web UI on indexer (recommended in distributed mode)
  log "Disabling Web UI on indexer..."
  splunk_cmd disable webserver -auth "$SPLUNK_ADMIN_USER:$SPLUNK_ADMIN_PASS"

  # Restart to apply web disable cleanly
  splunk_cmd restart
  # (Optional) Basic hardening/limits could be added here (ulimits, THP, etc.)
  log "Indexer configured."
}

# -------------------------
# Mode: Search Head
# -------------------------
configure_search_head() {
  log "Configuring SEARCH HEAD..."

  [[ -n "$INDEXER_HOST" ]] || die "INDEXER_HOST is required for search-head mode."
  local i_user="$INDEXER_ADMIN_USER"
  local i_pass="${INDEXER_ADMIN_PASS:-$SPLUNK_ADMIN_PASS}"
  [[ -n "$i_pass" ]] || die "INDEXER_ADMIN_PASS or SPLUNK_ADMIN_PASS is required."

  # Add indexer as search peer (distributed search)
  log "Adding search peer: $INDEXER_HOST:$INDEXER_MGMT_PORT ..."
  splunk_cmd add search-server "https://${INDEXER_HOST}:${INDEXER_MGMT_PORT}" \
    -auth "$SPLUNK_ADMIN_USER:$SPLUNK_ADMIN_PASS" \
    -remoteUsername "$i_user" -remotePassword "$i_pass"

  log "Search head configured."
}

show_usage() {
  cat <<'EOF'
Usage:
  splunk_auto.sh install
  splunk_auto.sh single
  splunk_auto.sh indexer
  splunk_auto.sh searchhead

Required env vars:
  One of:
    SPLUNK_TGZ=/path/to/splunk-*.tgz
    SPLUNK_TGZ_URL=https://.../splunk-*.tgz

  And for configuration steps:
    SPLUNK_ADMIN_PASS=YourStrongPassword

Distributed mode (search head requires):
  INDEXER_HOST=1.2.3.4 (or hostname)
  Optional:
    INDEXER_ADMIN_PASS=... (if different from SPLUNK_ADMIN_PASS)

Common optional env vars:
  SPLUNK_HOME=/opt/splunk
  SPLUNK_USER=splunk
  SPLUNK_GROUP=splunk
  SPLUNK_SERVER_NAME=MySplunkNodeName

Examples:

1) Single instance (all-in-one):
  sudo SPLUNK_TGZ=/tmp/splunk.tgz SPLUNK_ADMIN_PASS='P@ssw0rd!' ./splunk_auto.sh single

2) Indexer node:
  sudo SPLUNK_TGZ=/tmp/splunk.tgz SPLUNK_ADMIN_PASS='P@ssw0rd!' SPLUNK_SERVER_NAME='idx-01' ./splunk_auto.sh indexer

3) Search head node (points to indexer):
  sudo SPLUNK_TGZ=/tmp/splunk.tgz SPLUNK_ADMIN_PASS='P@ssw0rd!' \
    INDEXER_HOST=10.10.10.11 SPLUNK_SERVER_NAME='sh-01' ./splunk_auto.sh searchhead
EOF
}

do_install_only() {
  need_root
  install_deps
  ensure_user_group
  fetch_tgz_if_needed
  extract_splunk
  write_user_seed
  set_servername_if_provided
  first_start_and_enable_boot
  configure_common_ports
  log "Install complete."
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    install)
      do_install_only
      ;;
    single)
      do_install_only
      configure_single
      ;;
    indexer)
      do_install_only
      configure_indexer
      ;;
    searchhead)
      do_install_only
      configure_search_head
      ;;
    -h|--help|"")
      show_usage
      ;;
    *)
      die "Unknown command: $cmd (use --help)"
      ;;
  esac
}

main "$@"
