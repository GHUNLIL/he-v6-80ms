#!/usr/bin/env bash
set -Eeuo pipefail

# AWS 服务端：WireGuard + Phantun(FakeTCP) 一键重构脚本
# 适用：Debian / Ubuntu，需 root 运行

WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-44055}"
FAKETCP_PORT="${FAKETCP_PORT:-44445}"
WG_ADDRESS="${WG_ADDRESS:-4.4.4.1/24}"
CLIENT_WG_ALLOWED_IP="${CLIENT_WG_ALLOWED_IP:-4.4.4.2/32}"
WG_MTU="${WG_MTU:-1280}"
PHANTUN_IMAGE="${PHANTUN_IMAGE:-ghcr.io/akafeng/phantun}"
CONTAINER_NAME="${CONTAINER_NAME:-phantun-server}"

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
SERVER_PRIVATE_KEY_FILE="${WG_DIR}/${WG_IF}_server_private.key"
SERVER_PUBLIC_KEY_FILE="${WG_DIR}/${WG_IF}_server_public.key"
RST_GUARD_SERVICE="/etc/systemd/system/phantun-rst-guard-server.service"

log() {
  printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

fatal() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

on_error() {
  fatal "脚本执行失败，出错行号：$1。请查看上方日志。"
}
trap 'on_error $LINENO' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || fatal "请使用 root 运行：sudo bash $0"
}

require_debian_like() {
  [[ -r /etc/os-release ]] || fatal "无法识别系统发行版。"
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID_LIKE:-$ID}" in
    *debian*|*ubuntu*) ;;
    *) fatal "当前脚本仅面向 Debian/Ubuntu。检测到：${PRETTY_NAME:-unknown}" ;;
  esac
}

apt_install_base() {
  export DEBIAN_FRONTEND=noninteractive
  log "安装/确认基础组件：wireguard-tools、iptables、psmisc、curl、kmod、ping。"
  apt-get update
  apt-get install -y wireguard-tools iproute2 iptables psmisc curl ca-certificates kmod iputils-ping
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker 已安装：$(docker --version)"
  else
    warn "未检测到 Docker，尝试通过 apt 安装 docker.io。"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y docker.io
  fi

  systemctl enable --now docker
  docker info >/dev/null 2>&1 || fatal "Docker daemon 不可用，请检查 systemctl status docker。"
}

ensure_tun_device() {
  if [[ ! -e /dev/net/tun ]]; then
    log "加载 tun 内核模块。"
    modprobe tun || true
  fi
  [[ -e /dev/net/tun ]] || fatal "/dev/net/tun 不存在，Docker Phantun 无法创建 TUN 设备。"
}

extract_private_key_from_existing_conf() {
  [[ -r "${WG_CONF}" ]] || return 1
  awk -F'= *' '/^[[:space:]]*PrivateKey[[:space:]]*=/{print $2; exit}' "${WG_CONF}"
}

extract_first_peer_public_key_from_existing_conf() {
  [[ -r "${WG_CONF}" ]] || return 1
  awk -F'= *' '
    /^\[Peer\]/{in_peer=1; next}
    in_peer && /^[[:space:]]*PublicKey[[:space:]]*=/{print $2; exit}
  ' "${WG_CONF}"
}

ensure_wireguard_keys() {
  mkdir -p "${WG_DIR}"
  chmod 700 "${WG_DIR}"
  umask 077

  if [[ -s "${SERVER_PRIVATE_KEY_FILE}" ]]; then
    log "复用已有服务端私钥：${SERVER_PRIVATE_KEY_FILE}"
  else
    local existing_private_key
    existing_private_key="$(extract_private_key_from_existing_conf || true)"
    if [[ -n "${existing_private_key}" ]]; then
      log "从既有 ${WG_CONF} 复用服务端私钥。"
      printf '%s\n' "${existing_private_key}" > "${SERVER_PRIVATE_KEY_FILE}"
    else
      log "生成新的服务端 WireGuard 密钥。"
      wg genkey > "${SERVER_PRIVATE_KEY_FILE}"
    fi
  fi

  wg pubkey < "${SERVER_PRIVATE_KEY_FILE}" > "${SERVER_PUBLIC_KEY_FILE}"
  chmod 600 "${SERVER_PRIVATE_KEY_FILE}" "${SERVER_PUBLIC_KEY_FILE}"

  log "AWS 服务端 WireGuard 公钥如下，请填入 MKCloud 客户端脚本："
  cat "${SERVER_PUBLIC_KEY_FILE}"
}

prompt_client_public_key() {
  local default_peer_key="${CLIENT_PUBLIC_KEY:-}"
  if [[ -z "${default_peer_key}" ]]; then
    default_peer_key="$(extract_first_peer_public_key_from_existing_conf || true)"
  fi

  if [[ -n "${default_peer_key}" ]]; then
    read -r -p "请输入 MKCloud 客户端 WireGuard 公钥 [回车复用现有值]: " CLIENT_PUBLIC_KEY_INPUT
    CLIENT_PUBLIC_KEY="${CLIENT_PUBLIC_KEY_INPUT:-$default_peer_key}"
  else
    read -r -p "请输入 MKCloud 客户端 WireGuard 公钥: " CLIENT_PUBLIC_KEY
  fi

  [[ -n "${CLIENT_PUBLIC_KEY}" ]] || fatal "客户端 WireGuard 公钥不能为空。"
}

stop_old_services_and_free_port() {
  log "停止旧的 ${CONTAINER_NAME} 容器和 ${WG_IF} 接口，释放 UDP ${WG_PORT}。"
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  wg-quick down "${WG_IF}" >/dev/null 2>&1 || true

  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${WG_PORT}/udp" >/dev/null 2>&1 || true
  fi
}

write_sysctl_forwarding() {
  log "开启 IPv4 内核转发。"
  cat >/etc/sysctl.d/99-wg-phantun-forward.conf <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

write_wireguard_conf() {
  local server_private_key
  local backup_path
  server_private_key="$(cat "${SERVER_PRIVATE_KEY_FILE}")"

  if [[ -f "${WG_CONF}" ]]; then
    backup_path="${WG_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${WG_CONF}" "${backup_path}"
    log "已备份旧配置到 ${backup_path}。"
  fi

  log "写入 ${WG_CONF}。"
  umask 077
  cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${WG_ADDRESS}
ListenPort = ${WG_PORT}
PrivateKey = ${server_private_key}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_WG_ALLOWED_IP}
EOF
  chmod 600 "${WG_CONF}"
}

ensure_iptables_rule() {
  local table="$1"
  shift
  if [[ "${table}" == "filter" ]]; then
    iptables -C "$@" 2>/dev/null || iptables -I "$@"
  else
    iptables -t "${table}" -C "$@" 2>/dev/null || iptables -t "${table}" -I "$@"
  fi
}

ensure_ip6tables_rule() {
  ip6tables -C "$@" 2>/dev/null || ip6tables -I "$@"
}

apply_firewall_rules() {
  log "配置转发规则和 FakeTCP RST 防护。"
  ensure_iptables_rule filter FORWARD -i "${WG_IF}" -j ACCEPT
  ensure_iptables_rule filter FORWARD -o "${WG_IF}" -j ACCEPT
  ensure_ip6tables_rule INPUT -p tcp --dport "${FAKETCP_PORT}" -j DROP
}

install_rst_guard_service() {
  log "写入开机自动恢复防火墙规则的 systemd 服务。"
  cat > "${RST_GUARD_SERVICE}" <<EOF
[Unit]
Description=Phantun server RST guard and WireGuard forwarding rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/sbin/iptables -C FORWARD -i ${WG_IF} -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I FORWARD -i ${WG_IF} -j ACCEPT'
ExecStart=/bin/sh -c '/usr/sbin/iptables -C FORWARD -o ${WG_IF} -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I FORWARD -o ${WG_IF} -j ACCEPT'
ExecStart=/bin/sh -c '/usr/sbin/ip6tables -C INPUT -p tcp --dport ${FAKETCP_PORT} -j DROP 2>/dev/null || /usr/sbin/ip6tables -I INPUT -p tcp --dport ${FAKETCP_PORT} -j DROP'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$(basename "${RST_GUARD_SERVICE}")"
}

start_wireguard() {
  log "启动并设为开机自启：wg-quick@${WG_IF}。"
  systemctl enable "wg-quick@${WG_IF}"
  systemctl restart "wg-quick@${WG_IF}"
}

start_phantun_server() {
  log "拉取 Phantun 镜像：${PHANTUN_IMAGE}。"
  docker pull "${PHANTUN_IMAGE}"

  log "启动 Phantun 服务端容器：FakeTCP [::]:${FAKETCP_PORT} -> UDP 127.0.0.1:${WG_PORT}。"
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --network=host \
    --device=/dev/net/tun \
    --cap-add=NET_ADMIN \
    --restart=unless-stopped \
    "${PHANTUN_IMAGE}" \
    --local "127.0.0.1:${WG_PORT}" \
    --listen "[::]:${FAKETCP_PORT}"
}

show_status() {
  log "当前 WireGuard 状态："
  wg || true

  log "当前 Phantun 容器状态："
  docker ps --filter "name=${CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

  log "完成。请确认 AWS 安全组放行 IPv6 TCP ${FAKETCP_PORT} 入站。"
}

main() {
  require_root
  require_debian_like
  apt_install_base

  if [[ "${1:-}" == "--print-key" ]]; then
    ensure_wireguard_keys
    exit 0
  fi

  ensure_docker
  ensure_tun_device
  ensure_wireguard_keys
  prompt_client_public_key
  stop_old_services_and_free_port
  write_sysctl_forwarding
  write_wireguard_conf
  apply_firewall_rules
  install_rst_guard_service
  start_wireguard
  start_phantun_server
  show_status
}

main "$@"
