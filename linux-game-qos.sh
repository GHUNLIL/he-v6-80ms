#!/usr/bin/env bash
set -Eeuo pipefail

# Linux game-first QoS for WireGuard/Phantun relay hosts.
# It marks game ports with nftables, then uses tc/HTB to cap total egress
# bandwidth and give marked packets priority over other traffic.

SCRIPT_VERSION="2026-05-19.1"
RATE="${RATE:-400mbit}"
GAME_RATE="${GAME_RATE:-50mbit}"
OTHER_RATE="${OTHER_RATE:-10mbit}"
GAME_PORTS="${GAME_PORTS:-8080}"
FAKETCP_PORTS="${FAKETCP_PORTS:-44445}"
IFACE="${IFACE:-}"
TUN_IFACE="${TUN_IFACE:-wg0}"
SHAPE_PUBLIC="${SHAPE_PUBLIC:-1}"
SHAPE_TUNNEL="${SHAPE_TUNNEL:-1}"
GAME_MARK="${GAME_MARK:-0x10}"
QOS_TABLE="${QOS_TABLE:-game_qos}"
SERVICE_NAME="${SERVICE_NAME:-game-qos.service}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
ENV_FILE="${ENV_FILE:-/etc/default/game-qos}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/linux-game-qos.sh}"

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

require_root() {
  [[ "${EUID}" -eq 0 ]] || fatal "请使用 root 运行：sudo bash $0"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "缺少命令：$1"
}

detect_public_if() {
  local detected_if

  detected_if="$(ip -4 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  if [[ -z "${detected_if}" ]]; then
    detected_if="$(ip -6 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  fi

  [[ -n "${detected_if}" ]] || fatal "无法自动识别公网出口网卡，请用 IFACE=ens3 指定。"
  printf '%s\n' "${detected_if}"
}

ensure_iface() {
  local dev="$1"
  ip link show dev "${dev}" >/dev/null 2>&1 || fatal "接口不存在：${dev}"
}

install_deps() {
  if ! command -v tc >/dev/null 2>&1 || ! command -v nft >/dev/null 2>&1; then
    log "安装 iproute2 与 nftables。"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 nftables
  fi
}

normalize_port_set() {
  local raw="$1"
  local item start end
  local output=""

  raw="${raw//,/ }"
  for item in ${raw}; do
    if [[ "${item}" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      (( start >= 1 && start <= 65535 && end >= 1 && end <= 65535 && start <= end )) \
        || fatal "端口范围非法：${item}"
      item="${start}-${end}"
    elif [[ "${item}" =~ ^[0-9]{1,5}$ ]]; then
      (( item >= 1 && item <= 65535 )) || fatal "端口非法：${item}"
    else
      fatal "端口格式错误：${item}。请用 8080 或 30000-30100。"
    fi

    if [[ -n "${output}" ]]; then
      output="${output}, ${item}"
    else
      output="${item}"
    fi
  done

  [[ -n "${output}" ]] || fatal "端口集合不能为空。"
  printf '%s\n' "${output}"
}

write_nft_marks() {
  local game_ports faketcp_ports tmp_file

  game_ports="$(normalize_port_set "${GAME_PORTS}")"
  faketcp_ports="$(normalize_port_set "${FAKETCP_PORTS}")"
  tmp_file="$(mktemp)"

  cat > "${tmp_file}" <<EOF
table inet ${QOS_TABLE} {
    set game_ports {
        type inet_service
        flags interval
        elements = { ${game_ports} }
    }

    set faketcp_ports {
        type inet_service
        flags interval
        elements = { ${faketcp_ports} }
    }

    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        meta l4proto tcp tcp dport @game_ports meta mark set ${GAME_MARK}
        meta l4proto tcp tcp sport @game_ports meta mark set ${GAME_MARK}
        meta l4proto udp udp dport @game_ports meta mark set ${GAME_MARK}
        meta l4proto udp udp sport @game_ports meta mark set ${GAME_MARK}
        meta nfproto ipv6 meta l4proto tcp tcp dport @faketcp_ports meta mark set ${GAME_MARK}
        meta nfproto ipv6 meta l4proto tcp tcp sport @faketcp_ports meta mark set ${GAME_MARK}
    }

    chain output {
        type route hook output priority mangle; policy accept;
        meta l4proto tcp tcp dport @game_ports meta mark set ${GAME_MARK}
        meta l4proto tcp tcp sport @game_ports meta mark set ${GAME_MARK}
        meta l4proto udp udp dport @game_ports meta mark set ${GAME_MARK}
        meta l4proto udp udp sport @game_ports meta mark set ${GAME_MARK}
        meta nfproto ipv6 meta l4proto tcp tcp dport @faketcp_ports meta mark set ${GAME_MARK}
        meta nfproto ipv6 meta l4proto tcp tcp sport @faketcp_ports meta mark set ${GAME_MARK}
    }
}
EOF

  nft -c -f "${tmp_file}"
  nft delete table inet "${QOS_TABLE}" >/dev/null 2>&1 || true
  nft -f "${tmp_file}"
  rm -f "${tmp_file}"
}

apply_tc_dev() {
  local dev="$1"

  ensure_iface "${dev}"
  tc qdisc replace dev "${dev}" root handle 1: htb default 20
  tc class replace dev "${dev}" parent 1: classid 1:1 htb rate "${RATE}" ceil "${RATE}"
  tc class replace dev "${dev}" parent 1:1 classid 1:10 htb rate "${GAME_RATE}" ceil "${RATE}" prio 0
  tc class replace dev "${dev}" parent 1:1 classid 1:20 htb rate "${OTHER_RATE}" ceil "${RATE}" prio 7
  tc qdisc replace dev "${dev}" parent 1:10 fq_codel target 5ms interval 100ms quantum 300
  tc qdisc replace dev "${dev}" parent 1:20 fq_codel target 10ms interval 100ms quantum 300
  tc filter replace dev "${dev}" parent 1: protocol all prio 1 handle "${GAME_MARK}" fw classid 1:10

  log "已应用 QoS 到 ${dev}: 总限速 ${RATE}, 游戏保底 ${GAME_RATE}, 其他保底 ${OTHER_RATE}。"
}

apply_qos() {
  local public_if="${IFACE}"

  install_deps
  [[ -n "${public_if}" ]] || public_if="$(detect_public_if)"

  write_nft_marks

  if [[ "${SHAPE_PUBLIC}" == "1" ]]; then
    apply_tc_dev "${public_if}"
  fi

  if [[ "${SHAPE_TUNNEL}" == "1" ]]; then
    if ip link show dev "${TUN_IFACE}" >/dev/null 2>&1; then
      apply_tc_dev "${TUN_IFACE}"
    else
      warn "未找到 ${TUN_IFACE}，跳过隧道内层 QoS。"
    fi
  fi
}

clear_tc_dev() {
  local dev="$1"
  ip link show dev "${dev}" >/dev/null 2>&1 || return 0
  tc qdisc del dev "${dev}" root >/dev/null 2>&1 || true
}

clear_qos() {
  local public_if="${IFACE}"

  [[ -n "${public_if}" ]] || public_if="$(detect_public_if || true)"
  [[ -n "${public_if}" ]] && clear_tc_dev "${public_if}"
  clear_tc_dev "${TUN_IFACE}"
  nft delete table inet "${QOS_TABLE}" >/dev/null 2>&1 || true
  log "已清除 QoS。"
}

status_qos() {
  local public_if="${IFACE}"

  [[ -n "${public_if}" ]] || public_if="$(detect_public_if)"

  printf '\n[配置]\n'
  printf 'RATE=%s GAME_RATE=%s OTHER_RATE=%s GAME_PORTS=%s FAKETCP_PORTS=%s\n' \
    "${RATE}" "${GAME_RATE}" "${OTHER_RATE}" "${GAME_PORTS}" "${FAKETCP_PORTS}"
  printf 'IFACE=%s TUN_IFACE=%s SHAPE_PUBLIC=%s SHAPE_TUNNEL=%s\n' \
    "${public_if}" "${TUN_IFACE}" "${SHAPE_PUBLIC}" "${SHAPE_TUNNEL}"

  printf '\n[nft marks]\n'
  nft list table inet "${QOS_TABLE}" 2>/dev/null || warn "未找到 nft table inet ${QOS_TABLE}"

  printf '\n[tc public]\n'
  tc -s class show dev "${public_if}" 2>/dev/null || true
  tc -s qdisc show dev "${public_if}" 2>/dev/null || true

  if ip link show dev "${TUN_IFACE}" >/dev/null 2>&1; then
    printf '\n[tc tunnel]\n'
    tc -s class show dev "${TUN_IFACE}" 2>/dev/null || true
    tc -s qdisc show dev "${TUN_IFACE}" 2>/dev/null || true
  fi
}

write_env_file() {
  cat > "${ENV_FILE}" <<EOF
RATE="${RATE}"
GAME_RATE="${GAME_RATE}"
OTHER_RATE="${OTHER_RATE}"
GAME_PORTS="${GAME_PORTS}"
FAKETCP_PORTS="${FAKETCP_PORTS}"
IFACE="${IFACE}"
TUN_IFACE="${TUN_IFACE}"
SHAPE_PUBLIC="${SHAPE_PUBLIC}"
SHAPE_TUNNEL="${SHAPE_TUNNEL}"
GAME_MARK="${GAME_MARK}"
QOS_TABLE="${QOS_TABLE}"
EOF
}

install_service() {
  install_deps
  install -m 0755 "$0" "${INSTALL_PATH}"
  write_env_file

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Game-first tc/nft QoS
After=network-online.target wg-quick@${TUN_IFACE}.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${ENV_FILE}
ExecStart=${INSTALL_PATH} apply
ExecStop=${INSTALL_PATH} clear
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  log "已安装并启用 ${SERVICE_NAME}。"
}

usage() {
  cat <<EOF
用法：
  sudo RATE=400mbit GAME_PORTS=8080 bash $0 apply
  sudo RATE=400mbit GAME_PORTS=8080,30000-30100 bash $0 install
  sudo bash $0 status
  sudo bash $0 clear

常用变量：
  RATE=400mbit              整机出口总限速
  GAME_PORTS=8080           游戏/高优先端口，支持逗号和范围
  FAKETCP_PORTS=44445       Phantun FakeTCP 外层端口
  IFACE=ens3                公网网卡，默认自动识别
  TUN_IFACE=wg0             隧道内层接口
  GAME_RATE=50mbit          游戏类保底带宽
  OTHER_RATE=10mbit         其他类保底带宽
  SHAPE_PUBLIC=1            是否限制公网出口总带宽
  SHAPE_TUNNEL=1            是否限制/调度 wg0 内层流量

重要：
  如果游戏和下载都走同一个加密入口端口，系统无法区分包内业务。
  建议游戏用 8080，高流量下载另开 8081/其他端口，再只把 8080 放进 GAME_PORTS。
EOF
}

main() {
  require_root
  require_cmd ip

  case "${1:-apply}" in
    apply)
      apply_qos
      ;;
    install)
      install_service
      ;;
    clear | stop)
      clear_qos
      ;;
    status)
      status_qos
      ;;
    help | -h | --help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
