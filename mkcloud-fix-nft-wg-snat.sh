#!/usr/bin/env bash
set -Eeuo pipefail

# 修复 MKCloud 上 nftables 端口转发的回程 SNAT。
# 场景：本机端口 DNAT 到 WireGuard 目标，例如 4.4.4.1:8080。
# 正确回程必须 SNAT 为到目标的路由源地址，例如 4.4.4.2，而不是公网/内网出口 IP。

CONF_FILE="${CONF_FILE:-/etc/nftables.d/port-forward.conf}"
TABLE_NAME="${TABLE_NAME:-port_forward}"
WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
WG_MTU="${WG_MTU:-1380}"
PHANTUN_RST_PORT="${PHANTUN_RST_PORT:-44445}"

log() {
  printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}

fatal() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
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
      printf '   MK nftables SNAT 修复工具\n'
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

snat_ip_for_dest() {
  local dest_ip="$1"
  local src_ip

  src_ip="$(ip route get "${dest_ip}" 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "src") {
          print $(i + 1)
          exit
        }
      }
    }
  ')"

  [[ -n "${src_ip}" ]] || fatal "无法根据路由获取 ${dest_ip} 的源地址。"
  printf '%s\n' "${src_ip}"
}

load_rules_from_conf() {
  [[ -r "${CONF_FILE}" ]] || fatal "找不到配置文件：${CONF_FILE}"

  awk '
    /^[[:space:]]*tcp dport [0-9]+ dnat to [0-9.]+:[0-9]+/ {
      lport=$3
      split($6, target, ":")
      print lport "|" target[1] "|" target[2]
    }
  ' "${CONF_FILE}"
}

rewrite_conf() {
  local rules
  local tmp_file

  rules="$(load_rules_from_conf)"
  [[ -n "${rules}" ]] || fatal "未在 ${CONF_FILE} 中找到 tcp dport ... dnat to ... 规则。"

  cp -a "${CONF_FILE}" "${CONF_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  tmp_file="${CONF_FILE}.tmp.$$"

  {
    cat <<EOF
#!/usr/sbin/nft -f

table ip ${TABLE_NAME} {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF

    while IFS='|' read -r lport dip dport; do
      cat <<EOF

        # 转发: 本机:${lport} -> ${dip}:${dport}
        tcp dport ${lport} dnat to ${dip}:${dport}
        udp dport ${lport} dnat to ${dip}:${dport}
EOF
    done <<< "${rules}"

    cat <<EOF
    }

    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

    while IFS='|' read -r _lport dip dport; do
      local snat_ip
      snat_ip="$(snat_ip_for_dest "${dip}")"
      cat <<EOF

        # 回源: 发往 ${dip}:${dport} 的已 DNAT 流量，SNAT 为回程路由源地址 ${snat_ip}
        ip daddr ${dip} tcp dport ${dport} ct status dnat snat to ${snat_ip}
        ip daddr ${dip} udp dport ${dport} ct status dnat snat to ${snat_ip}
EOF
    done <<< "${rules}"

    cat <<EOF
    }
}
EOF
  } > "${tmp_file}"

  nft -c -f "${tmp_file}"
  mv -f "${tmp_file}" "${CONF_FILE}"
  nft delete table ip "${TABLE_NAME}" >/dev/null 2>&1 || true
  nft -f "${CONF_FILE}"
}

restore_phantun_rst_guard() {
  systemctl restart phantun-rst-guard-client.service >/dev/null 2>&1 || true
  ip6tables -C INPUT -p tcp --sport "${PHANTUN_RST_PORT}" -j DROP 2>/dev/null \
    || ip6tables -I INPUT -p tcp --sport "${PHANTUN_RST_PORT}" -j DROP
}

ensure_wg_mtu() {
  local tmp_file

  [[ -f "${WG_CONF}" ]] || return 0
  cp -a "${WG_CONF}" "${WG_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
  tmp_file="${WG_CONF}.tmp.$$"

  awk -v mtu="${WG_MTU}" '
    /^[[:space:]]*MTU[[:space:]]*=/ { next }
    /^\[Interface\]/ {
      print
      print "MTU = " mtu
      next
    }
    { print }
  ' "${WG_CONF}" > "${tmp_file}"

  mv -f "${tmp_file}" "${WG_CONF}"
  chmod 600 "${WG_CONF}"

  if ip link show wg0 >/dev/null 2>&1; then
    ip link set mtu "${WG_MTU}" dev wg0
  fi
}

run_repair() {
  require_root
  command -v nft >/dev/null 2>&1 || fatal "nft 命令不存在，请先安装 nftables。"
  rewrite_conf
  ensure_wg_mtu
  restore_phantun_rst_guard
  log "已修复 ${CONF_FILE} 并加载 nftables。当前规则："
  nft list table ip "${TABLE_NAME}"
  log "已恢复 Phantun FakeTCP RST 防护：ip6tables INPUT tcp --sport ${PHANTUN_RST_PORT} DROP。"
  log "已确保 WireGuard MTU = ${WG_MTU}，用于承载 Hysteria2/QUIC 1280 字节初始包。"
}

configure_custom() {
  clear >/dev/tty 2>/dev/null || true
  log "自定义 SNAT 修复参数。直接回车会使用括号内默认值。"
  prompt_value CONF_FILE "nftables 转发配置文件" "${CONF_FILE}"
  prompt_value TABLE_NAME "nftables 表名" "${TABLE_NAME}"
  prompt_value WG_CONF "WireGuard 配置文件" "${WG_CONF}"
  prompt_value WG_MTU "WireGuard MTU" "${WG_MTU}"
  prompt_value PHANTUN_RST_PORT "Phantun FakeTCP 端口" "${PHANTUN_RST_PORT}"
}

print_config() {
  cat <<EOF

[当前 SNAT 修复参数]
CONF_FILE=${CONF_FILE}
TABLE_NAME=${TABLE_NAME}
WG_CONF=${WG_CONF}
WG_MTU=${WG_MTU}
PHANTUN_RST_PORT=${PHANTUN_RST_PORT}

EOF
}

status_view() {
  print_config
  printf '\n[nftables]\n'
  nft list table ip "${TABLE_NAME}" 2>/dev/null || warn "nft table ip ${TABLE_NAME} 不存在"
  printf '\n[Phantun RST 防护]\n'
  ip6tables -S INPUT 2>/dev/null | grep "${PHANTUN_RST_PORT}" || warn "未看到 tcp --sport ${PHANTUN_RST_PORT} DROP 规则"
}

interactive_menu() {
  local answer

  while true; do
    choose_menu "MK nftables SNAT 修复工具" \
      "立即修复 SNAT/MTU/RST 防护" \
      "自定义参数后修复" \
      "查看当前状态" \
      "显示当前参数" \
      "退出" || exit 1

    case "${MENU_CHOICE}" in
      0)
        run_repair
        pause_ui
        ;;
      1)
        configure_custom
        print_config
        read_tty answer "确认按以上参数修复？输入 yes 继续: "
        [[ "${answer}" == "yes" ]] && run_repair || warn "已取消。"
        pause_ui
        ;;
      2)
        status_view
        pause_ui
        ;;
      3)
        print_config
        pause_ui
        ;;
      4)
        exit 0
        ;;
    esac
  done
}

usage() {
  cat <<EOF
用法：
  sudo bash $0          进入上下键菜单
  sudo bash $0 menu     进入上下键菜单
  sudo bash $0 repair   直接修复
  sudo bash $0 status   查看状态

常用环境变量：
  CONF_FILE=${CONF_FILE} TABLE_NAME=${TABLE_NAME}
  WG_CONF=${WG_CONF} WG_MTU=${WG_MTU} PHANTUN_RST_PORT=${PHANTUN_RST_PORT}
EOF
}

main() {
  case "${1:-menu}" in
    menu)
      require_root
      interactive_menu
      ;;
    repair | run | fix)
      run_repair
      ;;
    status)
      require_root
      status_view
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
