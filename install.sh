#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:-}"
if [[ -z "${REPO_URL}" ]]; then
  echo "Usage: sudo bash zap2-auto.sh <github_repo_url>"
  echo "Example: sudo bash zap2-auto.sh https://github.com/vernette/ss-zapret.git"
  exit 1
fi

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

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo bash $0 <repo_url>"
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
  # best-effort
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
  # "80,443" -> "{80,443}"
  local x="${1// /}"
  echo "{${x}}"
}

need_root

echo "[0] Detecting network..."
DEF_IF="$(detect_default_iface || true)"
if [[ -z "${DEF_IF}" ]]; then
  echo "Could not detect default interface. Check: ip route"
  exit 1
fi
LOCAL_CIDR="$(detect_local_ip "$DEF_IF")"
LOCAL_IP="${LOCAL_CIDR%%/*}"
PUB_IP="$(detect_public_ip || true)"

echo "  default iface: ${DEF_IF}"
echo "  local ip:      ${LOCAL_CIDR:-unknown}"
echo "  public ip:     ${PUB_IP:-unknown (will ask later)}"
echo

echo "[1] Installing packages (docker, wireguard, redsocks, nftables)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl git nano \
  docker.io docker-compose-plugin \
  wireguard nftables redsocks \
  iproute2 tcpdump openssl

systemctl enable --now docker

echo "[2] Cloning repo: ${REPO_URL}"
rm -rf "${INSTALL_DIR}"
git clone "${REPO_URL}" "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# prepare .env/config (best effort for vernette/ss-zapret* style)
if [[ -f ".env.example" && ! -f ".env" ]]; then
  cp .env.example .env
elif [[ -f ".env.sample" && ! -f ".env" ]]; then
  cp .env.sample .env
elif [[ ! -f ".env" ]]; then
  # create minimal .env if repo doesn't have an example
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

# set SOCKS_PORT and SS_PASSWORD if present/empty-ish
if [[ -f ".env" ]]; then
  set_env_kv ".env" "SOCKS_PORT" "${SOCKS_PORT}"

  if grep -qE '^SS_PASSWORD=' .env; then
    CURPW="$(grep -E '^SS_PASSWORD=' .env | head -n1 | cut -d= -f2- || true)"
    if [[ -z "${CURPW}" || "${CURPW}" == "changeme" ]]; then
      set_env_kv ".env" "SS_PASSWORD" "$(rand_pw)"
    fi
  else
    echo "SS_PASSWORD=$(rand_pw)" >> .env
  fi
fi

echo "[3] Starting docker compose..."
docker compose up -d
docker compose ps

echo "[4] WireGuard: generating keys (server + MikroTik peer)..."
install -d -m 700 /etc/wireguard

# server keys
if [[ ! -f "/etc/wireguard/server.key" ]]; then
  umask 077
  wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
fi
SERVER_PRIV="$(cat /etc/wireguard/server.key)"
SERVER_PUB="$(cat /etc/wireguard/server.pub)"

# MikroTik keys (we generate them so you can just paste to MT)
if [[ ! -f "/etc/wireguard/mikrotik.key" ]]; then
  umask 077
  wg genkey | tee /etc/wireguard/mikrotik.key | wg pubkey > /etc/wireguard/mikrotik.pub
fi
MT_PRIV="$(cat /etc/wireguard/mikrotik.key)"
MT_PUB="$(cat /etc/wireguard/mikrotik.pub)"

echo "[5] Enabling forwarding + rp_filter..."
cat >/etc/sysctl.d/99-zap2.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sysctl --system >/dev/null

echo "[6] Writing WireGuard config /etc/wireguard/${WG_IF}.conf ..."
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

systemctl enable --now "wg-quick@${WG_IF}"
sleep 1
wg show >/dev/null || true

echo "[7] Configuring redsocks (TCP -> SOCKS ${SOCKS_PORT})..."
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
systemctl enable --now redsocks

echo "[8] Configuring nftables redirect ONLY from ${WG_IF} to redsocks..."
NFT_PORT_SET="$(tcp_ports_to_nft_set "${TCP_PORTS}")"
cat >/etc/nftables.conf <<EOF
flush ruleset
table inet zap2 {
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;

    iifname "${WG_IF}" tcp dport ${NFT_PORT_SET} redirect to :${REDSOCKS_PORT}
  }
}
EOF
systemctl enable --now nftables

echo
echo "===================== OUTPUT (WireGuard for MikroTik) ====================="

# If public IP not detected, ask now (once)
if [[ -z "${PUB_IP}" ]]; then
  read -r -p "Public IP/DNS for MikroTik to connect (endpoint): " PUB_IP
fi

echo
echo "SERVER (Ubuntu) endpoint:"
echo "  ${PUB_IP}:${WG_PORT}"
echo
echo "WireGuard addressing:"
echo "  Server WG address:   ${WG_SERVER_ADDR}"
echo "  MikroTik WG address: ${WG_MT_ADDR%/*}/24  (set 10.99.0.2/24 on MT)"
echo
echo "Server public key (paste to MikroTik peer public-key):"
echo "  ${SERVER_PUB}"
echo
echo "MikroTik keys (generate once, paste into MikroTik wg interface):"
echo "  MikroTik PRIVATE key:"
echo "  ${MT_PRIV}"
echo "  MikroTik PUBLIC key (already added on server peer):"
echo "  ${MT_PUB}"
echo
echo "MikroTik peer settings (peer pointing to server):"
echo "  endpoint-address = ${PUB_IP}"
echo "  endpoint-port    = ${WG_PORT}"
echo "  allowed-address  = ${WG_SERVER_ADDR%/*}/32"
echo "  persistent-keepalive = 25s"
echo
echo "Routing hint on MikroTik:"
echo "  For marked traffic, set gateway/next-hop to: ${WG_SERVER_ADDR%/*}"
echo
echo "QUIC note:"
echo "  If you want this to work for HTTPS reliably, block UDP/443 for those clients on MikroTik."
echo
echo "Quick checks on Ubuntu:"
echo "  wg show"
echo "  nft -a list chain inet zap2 prerouting"
echo "  journalctl -u redsocks -n 50 --no-pager"
echo "  docker compose -f ${INSTALL_DIR}/docker-compose.yml ps"
echo "============================================================================"