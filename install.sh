#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:-}"
if [[ -z "${REPO_URL}" ]]; then
  echo "Usage: sudo bash install.sh <github_repo_url>"
  echo "Example: sudo bash install.sh https://github.com/vernette/ss-zapret.git"
  exit 1
fi

# ======== defaults (can be overridden via env vars) ========
INSTALL_DIR="${INSTALL_DIR:-/opt/ss-zapret}"
WG_NET="${WG_NET:-10.99.0.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.99.0.1/24}"
WG_CLIENT_IP="${WG_CLIENT_IP:-10.99.0.2/32}"
WG_PORT="${WG_PORT:-51820}"

SOCKS_PORT="${SOCKS_PORT:-1080}"          # from ss-zapret(.env.example)
REDSOCKS_PORT="${REDSOCKS_PORT:-12345}"
NFT_TCP_PORTS="${NFT_TCP_PORTS:-80,443}"  # redirected to redsocks
# ===========================================================

need_cmd() { command -v "$1" >/dev/null 2>&1; }

prompt_if_empty() {
  local var_name="$1"
  local prompt="$2"
  local secret="${3:-no}"
  local current="${!var_name:-}"
  if [[ -n "${current}" ]]; then return 0; fi
  if [[ "${secret}" == "yes" ]]; then
    read -r -s -p "${prompt}: " current
    echo
  else
    read -r -p "${prompt}: " current
  fi
  printf -v "${var_name}" "%s" "${current}"
}

echo "[1/9] Installing packages (docker, wireguard, nftables, redsocks)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl git nano \
  docker.io docker-compose-plugin \
  wireguard nftables redsocks \
  iproute2 tcpdump

systemctl enable --now docker

echo "[2/9] Cloning repo: ${REPO_URL}"
rm -rf "${INSTALL_DIR}"
git clone "${REPO_URL}" "${INSTALL_DIR}"

cd "${INSTALL_DIR}"

# Detect .env example filename
ENV_EXAMPLE=""
if [[ -f ".env.example" ]]; then ENV_EXAMPLE=".env.example"; fi
if [[ -z "${ENV_EXAMPLE}" && -f ".env.sample" ]]; then ENV_EXAMPLE=".env.sample"; fi

if [[ -n "${ENV_EXAMPLE}" && ! -f ".env" ]]; then
  echo "[3/9] Creating .env from ${ENV_EXAMPLE}"
  cp "${ENV_EXAMPLE}" .env
fi

# Some repos have config.default
if [[ -f "config.default" && ! -f "config" ]]; then
  echo "[3/9] Creating config from config.default"
  cp config.default config
fi

# Make sure SOCKS_PORT exists in .env (best effort)
if [[ -f ".env" ]]; then
  if grep -qE '^SOCKS_PORT=' .env; then
    sed -i "s/^SOCKS_PORT=.*/SOCKS_PORT=${SOCKS_PORT}/" .env || true
  else
    echo "SOCKS_PORT=${SOCKS_PORT}" >> .env
  fi
fi

# Ask for SS password if present and empty-ish
if [[ -f ".env" ]]; then
  if grep -qE '^SS_PASSWORD=' .env; then
    cur_pw="$(grep -E '^SS_PASSWORD=' .env | head -n1 | cut -d= -f2- || true)"
    if [[ -z "${cur_pw}" || "${cur_pw}" == "changeme" ]]; then
      SS_PASSWORD="${SS_PASSWORD:-}"
      prompt_if_empty SS_PASSWORD "Set SS_PASSWORD (any strong password)" "yes"
      sed -i "s/^SS_PASSWORD=.*/SS_PASSWORD=${SS_PASSWORD}/" .env
    fi
  fi
fi

echo "[4/9] Starting docker compose services..."
docker compose up -d
docker compose ps

echo "[5/9] WireGuard: generating keys..."
install -d -m 700 /etc/wireguard
if [[ ! -f /etc/wireguard/server.key ]]; then
  umask 077
  wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
fi
SERVER_PRIV="$(cat /etc/wireguard/server.key)"
SERVER_PUB="$(cat /etc/wireguard/server.pub)"

# We need MikroTik public key and endpoint info to print instructions
MT_PUBKEY="${MT_PUBKEY:-}"
prompt_if_empty MT_PUBKEY "Enter MikroTik WireGuard PUBLIC key (MT_PUBKEY)"

# Optional: public endpoint for MikroTik to reach this VM
ENDPOINT_HOST="${ENDPOINT_HOST:-}"
prompt_if_empty ENDPOINT_HOST "Enter this VM public IP/DNS for MikroTik endpoint (ENDPOINT_HOST)"

echo "[6/9] Writing /etc/wireguard/wg0.conf ..."
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

[Peer]
PublicKey = ${MT_PUBKEY}
AllowedIPs = ${WG_CLIENT_IP}
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf

echo "[7/9] Enabling IP forward + rp_filter settings..."
cat >/etc/sysctl.d/99-zapret-wg.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sysctl --system >/dev/null

systemctl enable --now wg-quick@wg0

echo "[8/9] Configuring redsocks..."
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

echo "[9/9] Configuring nftables (redirect TCP ${NFT_TCP_PORTS} from wg0 -> redsocks:${REDSOCKS_PORT})..."
# Convert "80,443" -> "{80,443}"
NFT_PORT_SET="{$(echo "${NFT_TCP_PORTS}" | tr -d ' ')}"
cat >/etc/nftables.conf <<EOF
flush ruleset
table inet zap {
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;
    iifname "wg0" tcp dport ${NFT_PORT_SET} redirect to :${REDSOCKS_PORT}
  }
}
EOF
systemctl enable --now nftables

echo
echo "====================== DONE ======================"
echo "Server WireGuard public key:"
echo "  ${SERVER_PUB}"
echo
echo "MikroTik endpoint (use this):"
echo "  ${ENDPOINT_HOST}:${WG_PORT}"
echo
echo "MikroTik addressing:"
echo "  MikroTik wg interface address: ${WG_CLIENT_IP%/*}/24  (e.g. 10.99.0.2/24)"
echo "  Server wg address: ${WG_SERVER_IP%/*}                (e.g. 10.99.0.1)"
echo
echo "MikroTik peer AllowedIPs should include:"
echo "  ${WG_SERVER_IP%/*}/32"
echo
echo "On MikroTik, route your marked traffic via gateway:"
echo "  ${WG_SERVER_IP%/*}"
echo
echo "Verification commands on Ubuntu:"
echo "  wg show"
echo "  nft -a list chain inet zap prerouting"
echo "  journalctl -u redsocks -n 50 --no-pager"
echo "  docker compose -f ${INSTALL_DIR}/docker-compose.yml ps"
echo "=================================================="