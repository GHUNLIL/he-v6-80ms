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

read_tty() {
  local __var="$1"
  local prompt="$2"
  local input=""

  if [[ -e /dev/tty ]]; then
    read -r -p "${prompt}" input </dev/tty
  else
    read -r -p "${prompt}" input
  fi
  printf -v "${__var}" '%s' "${input}"
}

prompt_value() {
  local __var="$1"
  local label="$2"
  local default_value="${3:-}"
  local input=""

  read_tty input "${label} [${default_value}]: "
  printf -v "${__var}" '%s' "${input:-${default_value}}"
}

pause_ui() {
  local _
  read_tty _ "按回车继续..."
}

choose_menu() {
  local title="$1"
  shift
  local options=("$@")
  local selected=0
  local key rest

  if [[ ! -e /dev/tty ]]; then
    local i choice
    printf '\n%s\n' "${title}"
    for i in "${!options[@]}"; do
      printf '  %s) %s\n' "$((i + 1))" "${options[$i]}"
    done
    read_tty choice "请选择 [1-${#options[@]}]: "
    [[ "${choice}" =~ ^[0-9]+$ ]] || return 1
    (( choice >= 1 && choice <= ${#options[@]} )) || return 1
    MENU_CHOICE=$((choice - 1))
    return 0
  fi

  while true; do
    clear >/dev/tty 2>/dev/null || true
    {
      printf '%s\n' "========================================"
      printf '   Linux 游戏优先 QoS\n'
      printf '   version: %s\n' "${SCRIPT_VERSION}"
      printf '%s\n' "========================================"
      printf '使用 ↑/↓ 选择，Enter 确认。\n\n'
      for key in "${!options[@]}"; do
        if [[ "${key}" -eq "${selected}" ]]; then
          printf '  \033[7m> %s\033[0m\n' "${options[$key]}"
        else
          printf '    %s\n' "${options[$key]}"
        fi
      done
    } >/dev/tty

    IFS= read -rsn1 key </dev/tty || return 1
    case "${key}" in
      $'\x1b')
        IFS= read -rsn2 -t 0.1 rest </dev/tty || rest=""
        case "${rest}" in
          "[A") (( selected > 0 )) && selected=$((selected - 1)) ;;
          "[B") (( selected < ${#options[@]} - 1 )) && selected=$((selected + 1)) ;;
        esac
        ;;
      "")
        MENU_CHOICE="${selected}"
        return 0
        ;;
    esac
  done
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
  sudo bash $0
  sudo bash $0 menu
  sudo env RATE=400mbit GAME_PORTS=8080 bash $0 apply
  sudo env RATE=400mbit GAME_PORTS=8080,30000-30100 bash $0 install
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

configure_custom() {
  clear >/dev/tty 2>/dev/null || true
  log "自定义游戏优先 QoS 参数。直接回车会使用括号内默认值。"
  prompt_value RATE "整机出口总限速" "${RATE}"
  prompt_value GAME_RATE "游戏类保底带宽" "${GAME_RATE}"
  prompt_value OTHER_RATE "其他类保底带宽" "${OTHER_RATE}"
  prompt_value GAME_PORTS "游戏/高优先端口，支持 8080,30000-30100" "${GAME_PORTS}"
  prompt_value FAKETCP_PORTS "Phantun FakeTCP 外层端口" "${FAKETCP_PORTS}"
  prompt_value IFACE "公网网卡，留空自动识别" "${IFACE}"
  prompt_value TUN_IFACE "隧道内层接口" "${TUN_IFACE}"
  prompt_value SHAPE_PUBLIC "是否调度公网出口，1/0" "${SHAPE_PUBLIC}"
  prompt_value SHAPE_TUNNEL "是否调度隧道内层，1/0" "${SHAPE_TUNNEL}"
  prompt_value GAME_MARK "nft/tc mark" "${GAME_MARK}"
  prompt_value QOS_TABLE "nftables 表名" "${QOS_TABLE}"
  prompt_value SERVICE_NAME "systemd 服务名" "${SERVICE_NAME}"
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
  prompt_value ENV_FILE "环境配置文件" "${ENV_FILE}"
  prompt_value INSTALL_PATH "脚本安装路径" "${INSTALL_PATH}"
}

print_config() {
  cat <<EOF

[当前 QoS 参数]
RATE=${RATE}
GAME_RATE=${GAME_RATE}
OTHER_RATE=${OTHER_RATE}
GAME_PORTS=${GAME_PORTS}
FAKETCP_PORTS=${FAKETCP_PORTS}
IFACE=${IFACE:-auto}
TUN_IFACE=${TUN_IFACE}
SHAPE_PUBLIC=${SHAPE_PUBLIC}
SHAPE_TUNNEL=${SHAPE_TUNNEL}
GAME_MARK=${GAME_MARK}
QOS_TABLE=${QOS_TABLE}
SERVICE_NAME=${SERVICE_NAME}
ENV_FILE=${ENV_FILE}
INSTALL_PATH=${INSTALL_PATH}

提示：如果游戏和下载共用同一个 HY2 端口，系统无法区分加密包内业务。
建议游戏端口放进 GAME_PORTS，下载/其他业务使用别的端口。

EOF
}

interactive_menu() {
  local answer

  while true; do
    choose_menu "Linux 游戏优先 QoS" \
      "立即应用 QoS（不安装开机自启）" \
      "安装/更新为开机自启服务" \
      "自定义参数后安装/更新" \
      "查看 QoS 状态" \
      "清除 QoS" \
      "显示当前参数" \
      "退出" || exit 1

    case "${MENU_CHOICE}" in
      0)
        apply_qos
        pause_ui
        ;;
      1)
        install_service
        pause_ui
        ;;
      2)
        configure_custom
        print_config
        read_tty answer "确认按以上参数安装/更新 QoS？输入 yes 继续: "
        [[ "${answer}" == "yes" ]] && install_service || warn "已取消。"
        pause_ui
        ;;
      3)
        status_qos
        pause_ui
        ;;
      4)
        clear_qos
        pause_ui
        ;;
      5)
        print_config
        pause_ui
        ;;
      6)
        exit 0
        ;;
    esac
  done
}

main() {
  case "${1:-menu}" in
    help | -h | --help)
      usage
      return
      ;;
  esac

  require_root
  require_cmd ip

  case "${1:-menu}" in
    menu)
      interactive_menu
      ;;
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
