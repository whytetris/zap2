#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Optional: pass repo URL. If omitted, installer uses current script directory as project root.
REPO_URL="${1:-}"

# ====== configurable defaults (override via env if you want) ======
INSTALL_DIR="${INSTALL_DIR:-/opt/ss-zapret}"
WG_IF="${WG_IF:-wg0}"
WG_NET_CIDR="${WG_NET_CIDR:-10.99.0.0/24}"
WG_SERVER_ADDR="${WG_SERVER_ADDR:-10.99.0.1/24}"
WG_MT_ADDR="${WG_MT_ADDR:-10.99.0.2/32}"
WG_PORT="${WG_PORT:-51820}"

SOCKS_PORT="${SOCKS_PORT:-1080}"      # expected in ss-zapret(.env.example)
REDSOCKS_PORT="${REDSOCKS_PORT:-12345}"
TCP_PORTS="${TCP_PORTS:-80,443}"      # which TCP ports to send via socks
# ================================================================

err() {
  echo "[ERROR] $*" >&2
}

info() {
  echo "[INFO] $*"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run as root: sudo bash ${SCRIPT_NAME} [repo_url]"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

rand_pw() {
  if have_cmd openssl; then
    openssl rand -base64 24 | tr -d '\n'
  else
    head -c 32 /dev/urandom | base64 | tr -d '\n'
  fi
}

detect_default_iface() {
  ip route show default 0.0.0.0/0 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

detect_local_ip() {
  local dev="$1"
  ip -4 -o addr show dev "$dev" | awk '{print $4}' | head -n1 || true
}

detect_public_ip() {
  local ip=""
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://checkip.amazonaws.com"
  do
    ip="$(curl -fsSL --max-time 4 "$url" 2>/dev/null || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  echo ""
}

set_env_kv() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

tcp_ports_to_nft_set() {
  local x="${1// /}"
  echo "{${x}}"
}

install_pkgs() {
  export DEBIAN_FRONTEND=noninteractive

  if have_cmd apt-get; then
    info "Installing packages via apt-get..."
    apt-get update -y
    apt-get install -y --no-install-recommends \
      ca-certificates curl git nano \
      docker.io docker-compose-plugin \
      wireguard nftables redsocks \
      iproute2 tcpdump openssl
  elif have_cmd dnf; then
    info "Installing packages via dnf..."
    dnf install -y \
      ca-certificates curl git nano \
      docker docker-compose-plugin \
      wireguard-tools nftables redsocks \
      iproute tcpdump openssl
  else
    err "Unsupported package manager. Need apt-get or dnf."
    exit 1
  fi
}

enable_service() {
  local svc="$1"
  systemctl enable --now "$svc" || {
    err "Failed to enable/start service: ${svc}"
    return 1
  }
}

ensure_docker_ready() {
  enable_service docker

  if docker info >/dev/null 2>&1; then
    return 0
  fi

  sleep 2
  docker info >/dev/null 2>&1 || {
    err "Docker daemon is not ready"
    exit 1
  }
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi
  err "Docker Compose plugin is not available (docker compose)."
  exit 1
}

resolve_project_dir() {
  if [[ -n "${REPO_URL}" ]]; then
    info "Using repository URL: ${REPO_URL}"
    rm -rf "${INSTALL_DIR}"
    git clone "${REPO_URL}" "${INSTALL_DIR}"
    echo "${INSTALL_DIR}"
    return
  fi

  if [[ -f "${SCRIPT_DIR}/docker-compose.yml" || -f "${SCRIPT_DIR}/docker-compose.yaml" ]]; then
    info "Using local project from script directory: ${SCRIPT_DIR}"
    echo "${SCRIPT_DIR}"
    return
  fi

  err "No repo URL provided and docker-compose file not found near script."
  err "Usage: sudo bash ${SCRIPT_NAME} <github_repo_url>"
  exit 1
}

prepare_project_env() {
  local proj_dir="$1"
  cd "${proj_dir}"

  if [[ -f ".env.example" && ! -f ".env" ]]; then
    cp .env.example .env
  elif [[ -f ".env.sample" && ! -f ".env" ]]; then
    cp .env.sample .env
  elif [[ ! -f ".env" ]]; then
    cat > .env <<EOF
SOCKS_PORT=${SOCKS_PORT}
SS_PORT=8388
SS_PASSWORD=$(rand_pw)
SS_ENCRYPT_METHOD=chacha20-ietf-poly1305
SS_TIMEOUT=300
EOF
  fi

  if [[ -f "config.default" && ! -f "config" ]]; then
    cp config.default config
  fi

  if [[ -f ".env" ]]; then
    set_env_kv ".env" "SOCKS_PORT" "${SOCKS_PORT}"

    if grep -qE '^SS_PASSWORD=' .env; then
      local curpw
      curpw="$(grep -E '^SS_PASSWORD=' .env | head -n1 | cut -d= -f2- || true)"
      if [[ -z "${curpw}" || "${curpw}" == "changeme" ]]; then
        set_env_kv ".env" "SS_PASSWORD" "$(rand_pw)"
      fi
    else
      echo "SS_PASSWORD=$(rand_pw)" >> .env
    fi
  fi
}

start_compose() {
  local proj_dir="$1"
  cd "${proj_dir}"

  if [[ -f "docker-compose.yml" || -f "docker-compose.yaml" ]]; then
    docker compose up -d
    docker compose ps
  else
    err "No docker-compose.yml/yaml in ${proj_dir}"
    exit 1
  fi
}

configure_wireguard() {
  info "WireGuard: generating keys (server + MikroTik peer)..."
  install -d -m 700 /etc/wireguard

  if [[ ! -f "/etc/wireguard/server.key" ]]; then
    umask 077
    wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
  fi
  SERVER_PRIV="$(cat /etc/wireguard/server.key)"
  SERVER_PUB="$(cat /etc/wireguard/server.pub)"

  if [[ ! -f "/etc/wireguard/mikrotik.key" ]]; then
    umask 077
    wg genkey | tee /etc/wireguard/mikrotik.key | wg pubkey > /etc/wireguard/mikrotik.pub
  fi
  MT_PRIV="$(cat /etc/wireguard/mikrotik.key)"
  MT_PUB="$(cat /etc/wireguard/mikrotik.pub)"

  info "Enabling forwarding + rp_filter..."
  cat >/etc/sysctl.d/99-zap2.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
  sysctl --system >/dev/null

  info "Writing /etc/wireguard/${WG_IF}.conf"
  cat >"/etc/wireguard/${WG_IF}.conf" <<EOF
[Interface]
Address = ${WG_SERVER_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

[Peer]
PublicKey = ${MT_PUB}
AllowedIPs = ${WG_MT_ADDR}
PersistentKeepalive = 25
EOF
  chmod 600 "/etc/wireguard/${WG_IF}.conf"

  enable_service "wg-quick@${WG_IF}.service"
  sleep 1
  wg show >/dev/null || true
}

configure_redsocks_and_nft() {
  info "Configuring redsocks"
  cat >/etc/redsocks.conf <<EOF
base {
  log_info = on;
  daemon = on;
  redirector = iptables;
}
redsocks {
  local_ip = 127.0.0.1;
  local_port = ${REDSOCKS_PORT};

  ip = 127.0.0.1;
  port = ${SOCKS_PORT};
  type = socks5;
}
EOF
  enable_service redsocks.service

  info "Configuring nftables redirect from ${WG_IF} to redsocks"
  local nft_port_set
  nft_port_set="$(tcp_ports_to_nft_set "${TCP_PORTS}")"
  cat >/etc/nftables.conf <<EOF
flush ruleset
table inet zap2 {
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;

    iifname "${WG_IF}" tcp dport ${nft_port_set} redirect to :${REDSOCKS_PORT}
  }
}
EOF
  enable_service nftables.service
}

print_summary() {
  local pub_ip="$1"

  echo
  echo "===================== OUTPUT (WireGuard for MikroTik) ====================="

  if [[ -z "${pub_ip}" ]]; then
    read -r -p "Public IP/DNS for MikroTik endpoint: " pub_ip
  fi

  echo
  echo "SERVER (Linux) endpoint:"
  echo "  ${pub_ip}:${WG_PORT}"
  echo
  echo "WireGuard addressing:"
  echo "  Server WG address:   ${WG_SERVER_ADDR}"
  echo "  MikroTik WG address: ${WG_MT_ADDR%/*}/24"
  echo
  echo "Server public key (paste to MikroTik peer public-key):"
  echo "  ${SERVER_PUB}"
  echo
  echo "MikroTik PRIVATE key:"
  echo "  ${MT_PRIV}"
  echo "MikroTik PUBLIC key (already added on server peer):"
  echo "  ${MT_PUB}"
  echo
  echo "MikroTik peer settings:"
  echo "  endpoint-address = ${pub_ip}"
  echo "  endpoint-port    = ${WG_PORT}"
  echo "  allowed-address  = ${WG_SERVER_ADDR%/*}/32"
  echo "  persistent-keepalive = 25s"
  echo
  echo "Quick checks on Linux:"
  echo "  wg show"
  echo "  nft -a list chain inet zap2 prerouting"
  echo "  journalctl -u redsocks -n 50 --no-pager"
  echo "  docker compose -f ${PROJECT_DIR}/docker-compose.yml ps"
  echo "============================================================================"
}

need_root

info "Detecting network..."
DEF_IF="$(detect_default_iface || true)"
if [[ -z "${DEF_IF}" ]]; then
  err "Could not detect default interface. Check: ip route"
  exit 1
fi
LOCAL_CIDR="$(detect_local_ip "${DEF_IF}")"
LOCAL_IP="${LOCAL_CIDR%%/*}"
PUB_IP="$(detect_public_ip || true)"

info "default iface: ${DEF_IF}"
info "local ip: ${LOCAL_CIDR:-unknown}"
info "public ip: ${PUB_IP:-unknown}"

install_pkgs
ensure_docker_ready
ensure_compose

PROJECT_DIR="$(resolve_project_dir)"
prepare_project_env "${PROJECT_DIR}"
start_compose "${PROJECT_DIR}"
configure_wireguard
configure_redsocks_and_nft
print_summary "${PUB_IP}"
