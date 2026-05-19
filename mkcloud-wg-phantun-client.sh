#!/usr/bin/env bash
set -Eeuo pipefail

# MKCloud 客户端：WireGuard + Phantun(FakeTCP) 一键重构脚本
# 适用：Debian / Ubuntu，需 root 运行

SCRIPT_VERSION="2026-05-19.8"
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-44055}"
FAKETCP_PORT="${FAKETCP_PORT:-44445}"
WG_ADDRESS="${WG_ADDRESS:-4.4.4.2/32}"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-4.4.4.0/24}"
WG_MTU="${WG_MTU:-1380}"
PHANTUN_VERSION="${PHANTUN_VERSION:-v0.8.1}"
PHANTUN_IMAGE="${PHANTUN_IMAGE:-local/phantun:${PHANTUN_VERSION}}"
CONTAINER_NAME="${CONTAINER_NAME:-phantun-client}"
PUBLIC_IF="${PUBLIC_IF:-}"
PHANTUN_TUN_NAME="${PHANTUN_TUN_NAME:-tun0}"
PHANTUN_CLIENT_TUN_NET_V6="${PHANTUN_CLIENT_TUN_NET_V6:-fcc8::/16}"
IFACE_TXQUEUELEN="${IFACE_TXQUEUELEN:-10000}"

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
CLIENT_PRIVATE_KEY_FILE="${WG_DIR}/${WG_IF}_client_private.key"
CLIENT_PUBLIC_KEY_FILE="${WG_DIR}/${WG_IF}_client_public.key"
RST_GUARD_SERVICE="/etc/systemd/system/phantun-rst-guard-client.service"

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
  log "安装/确认基础组件：wireguard-tools、iptables、psmisc、curl、kmod、ping、unzip。"
  apt-get update
  apt-get install -y wireguard-tools iproute2 iptables psmisc curl ca-certificates kmod iputils-ping unzip
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

phantun_target_triple() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) printf '%s\n' "aarch64-unknown-linux-musl" ;;
    armv7l) printf '%s\n' "armv7-unknown-linux-musleabihf" ;;
    armv6l|arm) printf '%s\n' "arm-unknown-linux-musleabihf" ;;
    i386|i686) printf '%s\n' "i686-unknown-linux-musl" ;;
    *) fatal "不支持的 CPU 架构：$(uname -m)。请手动设置 Phantun release target。" ;;
  esac
}

build_phantun_image() {
  local target
  local url
  local build_dir

  target="$(phantun_target_triple)"
  url="https://github.com/dndx/phantun/releases/download/${PHANTUN_VERSION}/phantun_${target}.zip"

  if docker image inspect "${PHANTUN_IMAGE}" >/dev/null 2>&1; then
    log "Phantun 本地镜像已存在：${PHANTUN_IMAGE}"
    return
  fi

  log "下载 Phantun ${PHANTUN_VERSION} (${target}) 并构建本地 Docker 镜像：${PHANTUN_IMAGE}。"
  build_dir="$(mktemp -d)"
  curl -fL "${url}" -o "${build_dir}/phantun.zip"
  unzip -qo "${build_dir}/phantun.zip" -d "${build_dir}"
  chmod +x "${build_dir}/phantun_client" "${build_dir}/phantun_server"

  cat > "${build_dir}/Dockerfile" <<EOF
FROM scratch
COPY phantun_client /usr/local/bin/phantun-client
COPY phantun_server /usr/local/bin/phantun-server
EOF

  docker build -t "${PHANTUN_IMAGE}" "${build_dir}"
  rm -rf "${build_dir}"
}

detect_public_if() {
  if [[ -n "${PUBLIC_IF}" ]]; then
    printf '%s\n' "${PUBLIC_IF}"
    return
  fi

  local detected_if
  detected_if="$(ip -6 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  if [[ -z "${detected_if}" ]]; then
    detected_if="$(ip route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  fi

  [[ -n "${detected_if}" ]] || fatal "无法自动识别公网出口网卡，请用 PUBLIC_IF=eth0 bash $0 指定。"
  printf '%s\n' "${detected_if}"
}

extract_private_key_from_existing_conf() {
  [[ -r "${WG_CONF}" ]] || return 1
  awk '/^[[:space:]]*PrivateKey[[:space:]]*=/{sub(/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*/, ""); print; exit}' "${WG_CONF}"
}

extract_first_peer_public_key_from_existing_conf() {
  [[ -r "${WG_CONF}" ]] || return 1
  awk -F'= *' '
    /^\[Peer\]/{in_peer=1; next}
    in_peer && /^[[:space:]]*PublicKey[[:space:]]*=/{sub(/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*/, ""); print; exit}
  ' "${WG_CONF}"
}

ensure_wireguard_keys() {
  mkdir -p "${WG_DIR}"
  chmod 700 "${WG_DIR}"
  umask 077

  if [[ -s "${CLIENT_PRIVATE_KEY_FILE}" ]]; then
    log "复用已有客户端私钥：${CLIENT_PRIVATE_KEY_FILE}"
  else
    local existing_private_key
    existing_private_key="$(extract_private_key_from_existing_conf || true)"
    if [[ -n "${existing_private_key}" ]]; then
      log "从既有 ${WG_CONF} 复用客户端私钥。"
      printf '%s\n' "${existing_private_key}" > "${CLIENT_PRIVATE_KEY_FILE}"
    else
      log "生成新的客户端 WireGuard 密钥。"
      wg genkey > "${CLIENT_PRIVATE_KEY_FILE}"
    fi
  fi

  wg pubkey < "${CLIENT_PRIVATE_KEY_FILE}" > "${CLIENT_PUBLIC_KEY_FILE}"
  chmod 600 "${CLIENT_PRIVATE_KEY_FILE}" "${CLIENT_PUBLIC_KEY_FILE}"

  log "MKCloud 客户端 WireGuard 公钥如下，请填入 AWS 服务端脚本："
  cat "${CLIENT_PUBLIC_KEY_FILE}"
}

prompt_server_public_key() {
  local default_peer_key="${SERVER_PUBLIC_KEY:-}"
  if [[ -z "${default_peer_key}" ]]; then
    default_peer_key="$(extract_first_peer_public_key_from_existing_conf || true)"
  fi

  if [[ -n "${default_peer_key}" ]]; then
    read -r -p "请输入 AWS 服务端 WireGuard 公钥 [回车复用现有值]: " SERVER_PUBLIC_KEY_INPUT
    SERVER_PUBLIC_KEY="${SERVER_PUBLIC_KEY_INPUT:-$default_peer_key}"
  else
    read -r -p "请输入 AWS 服务端 WireGuard 公钥: " SERVER_PUBLIC_KEY
  fi

  [[ -n "${SERVER_PUBLIC_KEY}" ]] || fatal "AWS 服务端 WireGuard 公钥不能为空。"
}

prompt_aws_ipv6() {
  local default_ipv6="${AWS_IPV6:-}"

  if [[ -n "${default_ipv6}" ]]; then
    read -r -p "请输入 AWS 公网 IPv6 地址 [回车复用 ${default_ipv6}]: " AWS_IPV6_INPUT
    AWS_IPV6="${AWS_IPV6_INPUT:-$default_ipv6}"
  else
    read -r -p "请输入 AWS 公网 IPv6 地址: " AWS_IPV6
  fi

  AWS_IPV6="${AWS_IPV6#[}"
  AWS_IPV6="${AWS_IPV6%]}"

  [[ -n "${AWS_IPV6}" ]] || fatal "AWS IPv6 地址不能为空。"
  [[ "${AWS_IPV6}" == *:* ]] || fatal "输入看起来不像 IPv6 地址：${AWS_IPV6}"
}

stop_old_services_and_free_port() {
  log "停止旧的 ${CONTAINER_NAME} 容器和 ${WG_IF} 接口，释放 UDP ${WG_PORT}。"
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  systemctl reset-failed "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  wg-quick down "${WG_IF}" >/dev/null 2>&1 || true
  ip link show dev "${WG_IF}" >/dev/null 2>&1 && ip link delete dev "${WG_IF}" >/dev/null 2>&1 || true
  ip link show dev "${PHANTUN_TUN_NAME}" >/dev/null 2>&1 && ip link delete dev "${PHANTUN_TUN_NAME}" >/dev/null 2>&1 || true

  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${WG_PORT}/udp" >/dev/null 2>&1 || true
  fi
}

write_wireguard_conf() {
  local client_private_key
  local backup_path
  client_private_key="$(cat "${CLIENT_PRIVATE_KEY_FILE}")"

  if [[ -f "${WG_CONF}" ]]; then
    backup_path="${WG_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${WG_CONF}" "${backup_path}"
    log "已备份旧配置到 ${backup_path}。"
  fi

  log "写入 ${WG_CONF}，Endpoint 固定为 127.0.0.1:${WG_PORT}。"
  umask 077
  cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${WG_ADDRESS}
PrivateKey = ${client_private_key}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = ${WG_ALLOWED_IPS}
Endpoint = 127.0.0.1:${WG_PORT}
PersistentKeepalive = 15
EOF
  chmod 600 "${WG_CONF}"
}

ensure_ip6tables_rule() {
  ip6tables -C "$@" 2>/dev/null || ip6tables -I "$@"
}

ensure_ip6tables_forward_rule() {
  ip6tables -C FORWARD "$@" 2>/dev/null || ip6tables -I FORWARD "$@"
}

ensure_ip6tables_nat_rule() {
  ip6tables -t nat -C "$@" 2>/dev/null || ip6tables -t nat -I "$@"
}

write_sysctl_forwarding() {
  log "开启 IPv4/IPv6 内核转发并优化高吞吐 UDP/FakeTCP 缓冲。"
  cat >/etc/sysctl.d/99-wg-phantun-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.icmp_echo_ignore_all=0
net.ipv6.conf.all.forwarding=1
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.optmem_max=67108864
net.core.netdev_max_backlog=250000
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.tcp_rmem=4096 87380 268435456
net.ipv4.tcp_wmem=4096 65536 268435456
EOF
  sysctl --system >/dev/null
}

apply_interface_queue_tuning() {
  local public_if
  public_if="$(detect_public_if)"
  log "设置接口队列长度，减少高 PPS UDP 压测时的突发丢包。"
  ip link set dev "${public_if}" txqueuelen "${IFACE_TXQUEUELEN}" >/dev/null 2>&1 || true
  ip link show dev "${WG_IF}" >/dev/null 2>&1 \
    && ip link set dev "${WG_IF}" txqueuelen "${IFACE_TXQUEUELEN}" >/dev/null 2>&1 || true
  ip link show dev "${PHANTUN_TUN_NAME}" >/dev/null 2>&1 \
    && ip link set dev "${PHANTUN_TUN_NAME}" txqueuelen "${IFACE_TXQUEUELEN}" >/dev/null 2>&1 || true
}

apply_firewall_rules() {
  local public_if
  public_if="$(detect_public_if)"
  log "配置 FakeTCP RST 防护。"
  ensure_ip6tables_rule INPUT -p tcp --sport "${FAKETCP_PORT}" -j DROP
  ensure_ip6tables_forward_rule -i "${PHANTUN_TUN_NAME}" -o "${public_if}" -j ACCEPT
  ensure_ip6tables_forward_rule -i "${public_if}" -o "${PHANTUN_TUN_NAME}" -j ACCEPT
  ensure_ip6tables_nat_rule POSTROUTING -s "${PHANTUN_CLIENT_TUN_NET_V6}" -o "${public_if}" -j MASQUERADE
}

install_rst_guard_service() {
  local public_if
  public_if="$(detect_public_if)"
  log "写入开机自动恢复 RST 防护规则的 systemd 服务。"
  cat > "${RST_GUARD_SERVICE}" <<EOF
[Unit]
Description=Phantun client RST guard rule
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/sbin/ip6tables -C INPUT -p tcp --sport ${FAKETCP_PORT} -j DROP 2>/dev/null || /usr/sbin/ip6tables -I INPUT -p tcp --sport ${FAKETCP_PORT} -j DROP'
ExecStart=/bin/sh -c '/usr/sbin/ip6tables -C FORWARD -i ${PHANTUN_TUN_NAME} -o ${public_if} -j ACCEPT 2>/dev/null || /usr/sbin/ip6tables -I FORWARD -i ${PHANTUN_TUN_NAME} -o ${public_if} -j ACCEPT'
ExecStart=/bin/sh -c '/usr/sbin/ip6tables -C FORWARD -i ${public_if} -o ${PHANTUN_TUN_NAME} -j ACCEPT 2>/dev/null || /usr/sbin/ip6tables -I FORWARD -i ${public_if} -o ${PHANTUN_TUN_NAME} -j ACCEPT'
ExecStart=/bin/sh -c '/usr/sbin/ip6tables -t nat -C POSTROUTING -s ${PHANTUN_CLIENT_TUN_NET_V6} -o ${public_if} -j MASQUERADE 2>/dev/null || /usr/sbin/ip6tables -t nat -I POSTROUTING -s ${PHANTUN_CLIENT_TUN_NET_V6} -o ${public_if} -j MASQUERADE'
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
  apply_interface_queue_tuning
}

start_phantun_client() {
  build_phantun_image

  log "启动 Phantun 客户端容器：UDP 0.0.0.0:${WG_PORT} -> FakeTCP [${AWS_IPV6}]:${FAKETCP_PORT}。"
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --network=host \
    --device=/dev/net/tun \
    --cap-add=NET_ADMIN \
    --restart=unless-stopped \
    "${PHANTUN_IMAGE}" \
    /usr/local/bin/phantun-client \
    --local "0.0.0.0:${WG_PORT}" \
    --remote "[${AWS_IPV6}]:${FAKETCP_PORT}" \
    --tun "${PHANTUN_TUN_NAME}"

  sleep 1
  [[ "$(docker inspect "${CONTAINER_NAME}" --format '{{.State.Running}}')" == "true" ]] \
    || { docker logs "${CONTAINER_NAME}" 2>&1 || true; fatal "Phantun 客户端容器启动失败。"; }
  apply_interface_queue_tuning
}

show_status_and_test() {
  log "等待 5 秒后执行 wg 与 ping 测试。"
  sleep 5

  log "当前 WireGuard 状态："
  wg || true

  log "测试 ping 4.4.4.1 -c 4："
  ping 4.4.4.1 -c 4 || warn "ping 未成功。请检查 AWS 安全组 IPv6 TCP ${FAKETCP_PORT}、两端公钥、Phantun 容器日志。"

  log "当前 Phantun 容器状态："
  docker ps --filter "name=${CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

main() {
  log "脚本版本：${SCRIPT_VERSION}"
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
  prompt_server_public_key
  prompt_aws_ipv6
  stop_old_services_and_free_port
  write_sysctl_forwarding
  write_wireguard_conf
  apply_firewall_rules
  install_rst_guard_service
  start_wireguard
  start_phantun_client
  show_status_and_test
}

main "$@"
