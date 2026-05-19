#!/usr/bin/env bash
set -Eeuo pipefail

# MKCloud nftables port forwarding manager.
# Supports single ports and same-size port ranges, for example:
#   8080 -> 4.4.4.1:8080
#   30000-30100 -> 4.4.4.1:30000-30100

SCRIPT_VERSION="2026-05-19.1"
CONF_FILE="${CONF_FILE:-/etc/nftables.d/port-forward.conf}"
TABLE_NAME="${TABLE_NAME:-port_forward}"
DEFAULT_TARGET="${DEFAULT_TARGET:-4.4.4.1}"
WG_IF="${WG_IF:-wg0}"
WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
WG_MTU="${WG_MTU:-1380}"
PHANTUN_RST_PORT="${PHANTUN_RST_PORT:-44445}"
MAX_EXPANDED_RULES="${MAX_EXPANDED_RULES:-2000}"

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

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

parse_port_range() {
  local spec="$1"
  local start end

  if [[ "${spec}" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[2]}"
  elif [[ "${spec}" =~ ^([0-9]{1,5})$ ]]; then
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[1]}"
  else
    fatal "端口格式错误：${spec}。请使用 8080 或 30000-30100。"
  fi

  (( start >= 1 && start <= 65535 )) || fatal "端口超出范围：${start}"
  (( end >= 1 && end <= 65535 )) || fatal "端口超出范围：${end}"
  (( start <= end )) || fatal "端口范围起始不能大于结束：${spec}"

  printf '%s %s\n' "${start}" "${end}"
}

range_to_text() {
  local start="$1"
  local end="$2"

  if [[ "${start}" == "${end}" ]]; then
    printf '%s\n' "${start}"
  else
    printf '%s-%s\n' "${start}" "${end}"
  fi
}

normalize_proto() {
  local proto="${1:-tcp+udp}"

  case "${proto}" in
    tcp | TCP)
      printf 'tcp\n'
      ;;
    udp | UDP)
      printf 'udp\n'
      ;;
    both | BOTH | all | ALL | tcp+udp | udp+tcp | '')
      printf 'tcp+udp\n'
      ;;
    *)
      fatal "协议格式错误：${proto}。可用：tcp、udp、tcp+udp。"
      ;;
  esac
}

proto_count() {
  [[ "$1" == "tcp+udp" ]] && printf '2\n' || printf '1\n'
}

proto_list() {
  if [[ "$1" == "tcp+udp" ]]; then
    printf 'tcp\nudp\n'
  else
    printf '%s\n' "$1"
  fi
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

  [[ -n "${src_ip}" ]] || fatal "无法根据路由获取 ${dest_ip} 的源地址。请先确认 WireGuard 路由已存在。"
  printf '%s\n' "${src_ip}"
}

ensure_nftables() {
  if ! command -v nft >/dev/null 2>&1; then
    log "安装 nftables。"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
  fi

  mkdir -p "$(dirname "${CONF_FILE}")"

  if [[ ! -f /etc/nftables.conf ]]; then
    cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

include "/etc/nftables.d/*.conf"
EOF
  fi

  if ! grep -Eq '^[[:space:]]*include[[:space:]]+"/etc/nftables\.d/\*\.conf"' /etc/nftables.conf; then
    printf '\ninclude "/etc/nftables.d/*.conf"\n' >>/etc/nftables.conf
  fi

  systemctl enable --now nftables >/dev/null 2>&1 || true
}

load_rules() {
  [[ -r "${CONF_FILE}" ]] || return 0

  if grep -q '^# forward-rule ' "${CONF_FILE}"; then
    awk '
      /^# forward-rule / {
        delete v
        for (i = 3; i <= NF; i++) {
          split($i, pair, "=")
          v[pair[1]] = pair[2]
        }
        if (v["proto"] != "" && v["local"] != "" && v["target"] != "" && v["target_port"] != "") {
          print v["proto"] "|" v["local"] "|" v["target"] "|" v["target_port"]
        }
      }
    ' "${CONF_FILE}" | while IFS='|' read -r proto local_spec target_ip target_spec; do
      local local_start local_end target_start target_end
      read -r local_start local_end < <(parse_port_range "${local_spec}")
      read -r target_start target_end < <(parse_port_range "${target_spec}")
      printf '%s|%s|%s|%s|%s|%s\n' \
        "$(normalize_proto "${proto}")" "${local_start}" "${local_end}" "${target_ip}" "${target_start}" "${target_end}"
    done
    return 0
  fi

  awk '
    /^[[:space:]]*(tcp|udp)[[:space:]]+dport[[:space:]]+[0-9]+[[:space:]]+dnat[[:space:]]+to[[:space:]]+[0-9.]+:[0-9]+/ {
      proto=$1
      local_port=$3
      target=$6
      split(target, target_parts, ":")
      print proto "|" local_port "|" target_parts[1] "|" target_parts[2]
    }
  ' "${CONF_FILE}" | while IFS='|' read -r proto local_spec target_ip target_spec; do
    local local_start local_end target_start target_end
    read -r local_start local_end < <(parse_port_range "${local_spec}")
    read -r target_start target_end < <(parse_port_range "${target_spec}")
    printf '%s|%s|%s|%s|%s|%s\n' \
      "$(normalize_proto "${proto}")" "${local_start}" "${local_end}" "${target_ip}" "${target_start}" "${target_end}"
  done
}

compact_rules() {
  awk -F'|' '
    NF == 6 {
      key = $2 FS $3 FS $4 FS $5 FS $6
      if (!(key in seen)) {
        seen[key] = ++count
        order[count] = key
        proto[key] = $1
      } else if (proto[key] != $1 && proto[key] != "tcp+udp") {
        proto[key] = "tcp+udp"
      }
    }
    END {
      for (i = 1; i <= count; i++) {
        key = order[i]
        split(key, v, FS)
        print proto[key] FS v[1] FS v[2] FS v[3] FS v[4] FS v[5]
      }
    }
  '
}

validate_rule() {
  local proto="$1"
  local local_start="$2"
  local local_end="$3"
  local target_ip="$4"
  local target_start="$5"
  local target_end="$6"
  local local_count target_count expanded

  is_ipv4 "${target_ip}" || fatal "目标地址必须是 IPv4，例如 4.4.4.1：${target_ip}"

  local_count=$((local_end - local_start + 1))
  target_count=$((target_end - target_start + 1))
  [[ "${local_count}" -eq "${target_count}" ]] \
    || fatal "本机端口范围和目标端口范围数量必须一致。"

  expanded=$((local_count * $(proto_count "${proto}")))
  (( expanded <= MAX_EXPANDED_RULES )) \
    || fatal "范围会展开 ${expanded} 条 DNAT 规则，超过限制 ${MAX_EXPANDED_RULES}。可用 MAX_EXPANDED_RULES=数量 覆盖。"
}

write_rules() {
  local rules="$1"
  local tmp_file

  ensure_nftables
  tmp_file="${CONF_FILE}.tmp.$$"
  [[ -f "${CONF_FILE}" ]] && cp -a "${CONF_FILE}" "${CONF_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

  {
    cat <<EOF
#!/usr/sbin/nft -f
# Generated by mkcloud-nft-port-forward.sh ${SCRIPT_VERSION}.
# Do not edit nft rules below by hand. Use this script to add/delete forwards.

table ip ${TABLE_NAME} {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF

    if [[ -n "${rules}" ]]; then
      while IFS='|' read -r proto local_start local_end target_ip target_start target_end; do
        local local_text target_text offset local_port target_port item_proto
        [[ -n "${proto}" ]] || continue
        validate_rule "${proto}" "${local_start}" "${local_end}" "${target_ip}" "${target_start}" "${target_end}"
        local_text="$(range_to_text "${local_start}" "${local_end}")"
        target_text="$(range_to_text "${target_start}" "${target_end}")"

        printf '\n        # forward-rule proto=%s local=%s target=%s target_port=%s\n' \
          "${proto}" "${local_text}" "${target_ip}" "${target_text}"
        offset=0
        while (( local_start + offset <= local_end )); do
          local_port=$((local_start + offset))
          target_port=$((target_start + offset))
          while read -r item_proto; do
            printf '        %s dport %s dnat to %s:%s\n' \
              "${item_proto}" "${local_port}" "${target_ip}" "${target_port}"
          done < <(proto_list "${proto}")
          offset=$((offset + 1))
        done
      done <<< "${rules}"
    fi

    cat <<EOF
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
EOF

    if [[ -n "${rules}" ]]; then
      while IFS='|' read -r proto local_start local_end target_ip target_start target_end; do
        local snat_ip offset target_port item_proto
        [[ -n "${proto}" ]] || continue
        snat_ip="$(snat_ip_for_dest "${target_ip}")"

        printf '\n        # SNAT for %s via route source %s\n' "${target_ip}" "${snat_ip}"
        offset=0
        while (( local_start + offset <= local_end )); do
          target_port=$((target_start + offset))
          while read -r item_proto; do
            printf '        ip daddr %s %s dport %s ct status dnat snat to %s\n' \
              "${target_ip}" "${item_proto}" "${target_port}" "${snat_ip}"
          done < <(proto_list "${proto}")
          offset=$((offset + 1))
        done
      done <<< "${rules}"
    fi

    cat <<EOF
    }
}
EOF
  } > "${tmp_file}"

  nft -c -f "${tmp_file}"
  mv -f "${tmp_file}" "${CONF_FILE}"
  nft delete table ip "${TABLE_NAME}" >/dev/null 2>&1 || true
  nft -f "${CONF_FILE}"
  restore_phantun_rst_guard
  ensure_wg_mtu
}

restore_phantun_rst_guard() {
  systemctl restart phantun-rst-guard-client.service >/dev/null 2>&1 || true
  ip6tables -C INPUT -p tcp --sport "${PHANTUN_RST_PORT}" -j DROP 2>/dev/null \
    || ip6tables -I INPUT -p tcp --sport "${PHANTUN_RST_PORT}" -j DROP
}

ensure_wg_mtu() {
  local tmp_file

  if [[ -f "${WG_CONF}" ]]; then
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
  fi

  if ip link show "${WG_IF}" >/dev/null 2>&1; then
    ip link set mtu "${WG_MTU}" dev "${WG_IF}"
  fi
}

current_rules() {
  load_rules | compact_rules
}

list_rules() {
  local rules="$1"
  local index=0

  if [[ -z "${rules}" ]]; then
    warn "当前没有端口转发规则。"
    return 0
  fi

  printf '\n%-5s %-9s %-15s %-22s\n' "序号" "协议" "本机端口" "目标地址"
  printf '%s\n' "--------------------------------------------------------"
  while IFS='|' read -r proto local_start local_end target_ip target_start target_end; do
    index=$((index + 1))
    printf '%-5s %-9s %-15s -> %s:%s\n' \
      "${index}" \
      "${proto}" \
      "$(range_to_text "${local_start}" "${local_end}")" \
      "${target_ip}" \
      "$(range_to_text "${target_start}" "${target_end}")"
  done <<< "${rules}"
}

add_rule() {
  local local_spec="${1:-}"
  local target_ip="${2:-}"
  local target_spec="${3:-}"
  local proto="${4:-}"
  local local_start local_end target_start target_end rules new_rule

  if [[ -z "${local_spec}" ]]; then
    read -rp "请输入本机端口或范围 [例如 8080 或 30000-30100]: " local_spec
  fi

  if [[ -z "${target_ip}" ]]; then
    read -rp "请输入目标 IPv4 地址 [默认 ${DEFAULT_TARGET}]: " target_ip
    target_ip="${target_ip:-${DEFAULT_TARGET}}"
  fi

  if [[ -z "${target_spec}" ]]; then
    read -rp "请输入目标端口或范围 [默认同本机端口]: " target_spec
    target_spec="${target_spec:-${local_spec}}"
  fi

  if [[ -z "${proto}" ]]; then
    read -rp "请输入协议 tcp/udp/tcp+udp [默认 tcp+udp]: " proto
    proto="${proto:-tcp+udp}"
  fi

  proto="$(normalize_proto "${proto}")"
  read -r local_start local_end < <(parse_port_range "${local_spec}")
  read -r target_start target_end < <(parse_port_range "${target_spec}")
  validate_rule "${proto}" "${local_start}" "${local_end}" "${target_ip}" "${target_start}" "${target_end}"

  rules="$(current_rules || true)"
  new_rule="${proto}|${local_start}|${local_end}|${target_ip}|${target_start}|${target_end}"
  if [[ -n "${rules}" ]]; then
    rules="${rules}"$'\n'"${new_rule}"
  else
    rules="${new_rule}"
  fi

  write_rules "${rules}"
  log "已添加转发：${proto} $(range_to_text "${local_start}" "${local_end}") -> ${target_ip}:$(range_to_text "${target_start}" "${target_end}")"
}

delete_rule() {
  local index="${1:-}"
  local rules new_rules line_no=0

  rules="$(current_rules || true)"
  [[ -n "${rules}" ]] || fatal "当前没有可删除的规则。"

  if [[ -z "${index}" ]]; then
    list_rules "${rules}"
    read -rp "请输入要删除的序号: " index
  fi

  [[ "${index}" =~ ^[0-9]+$ ]] || fatal "序号必须是数字。"

  new_rules=""
  while IFS= read -r line; do
    line_no=$((line_no + 1))
    if [[ "${line_no}" != "${index}" ]]; then
      if [[ -n "${new_rules}" ]]; then
        new_rules="${new_rules}"$'\n'"${line}"
      else
        new_rules="${line}"
      fi
    fi
  done <<< "${rules}"

  (( index >= 1 && index <= line_no )) || fatal "序号不存在：${index}"
  write_rules "${new_rules}"
  log "已删除第 ${index} 条转发。"
}

clear_rules() {
  local answer="${1:-}"

  if [[ "${answer}" != "yes" ]]; then
    read -rp "确认清空所有转发？输入 yes 继续: " answer
  fi

  [[ "${answer}" == "yes" ]] || fatal "已取消。"
  write_rules ""
  log "已清空所有转发。"
}

diagnose() {
  ensure_nftables

  printf '\n[基础状态]\n'
  systemctl is-active nftables 2>/dev/null || true
  ip link show "${WG_IF}" 2>/dev/null || warn "${WG_IF} 不存在"
  ip route get "${DEFAULT_TARGET}" 2>/dev/null || true

  printf '\n[当前转发]\n'
  list_rules "$(current_rules || true)"

  printf '\n[nftables 表]\n'
  nft list table ip "${TABLE_NAME}" 2>/dev/null || warn "nft table ip ${TABLE_NAME} 不存在"

  printf '\n[Phantun RST 防护]\n'
  ip6tables -S INPUT | grep "${PHANTUN_RST_PORT}" || warn "未看到 tcp --sport ${PHANTUN_RST_PORT} DROP 规则"
}

print_menu() {
  cat <<'EOF'

========================================
   nftables 端口转发管理工具 v2.0
========================================
  1) 安装/初始化 nftables
  2) 查看现有端口转发
  3) 新增端口转发
  4) 删除端口转发
  5) 一键清空所有转发
  6) 诊断/自检
  7) 退出
========================================
EOF
}

menu() {
  local choice

  while true; do
    print_menu
    read -rp "请选择操作 [1-7]: " choice
    case "${choice}" in
      1)
        ensure_nftables
        restore_phantun_rst_guard
        ensure_wg_mtu
        log "初始化完成。"
        ;;
      2)
        list_rules "$(current_rules || true)"
        ;;
      3)
        add_rule
        ;;
      4)
        delete_rule
        ;;
      5)
        clear_rules
        ;;
      6)
        diagnose
        ;;
      7)
        exit 0
        ;;
      *)
        warn "无效选择。"
        ;;
    esac
  done
}

usage() {
  cat <<EOF
用法：
  sudo bash $0
  sudo bash $0 install
  sudo bash $0 list
  sudo bash $0 add <本机端口或范围> <目标IPv4> [目标端口或范围] [tcp|udp|tcp+udp]
  sudo bash $0 delete <序号>
  sudo bash $0 clear yes
  sudo bash $0 diagnose

示例：
  sudo bash $0 add 8080 ${DEFAULT_TARGET} 8080 tcp+udp
  sudo bash $0 add 30000-30100 ${DEFAULT_TARGET} 30000-30100 udp
EOF
}

main() {
  require_root
  require_cmd ip
  require_cmd awk

  case "${1:-menu}" in
    menu)
      menu
      ;;
    install)
      ensure_nftables
      restore_phantun_rst_guard
      ensure_wg_mtu
      log "初始化完成。"
      ;;
    list)
      list_rules "$(current_rules || true)"
      ;;
    add)
      shift
      add_rule "$@"
      ;;
    delete | del | remove | rm)
      shift
      delete_rule "$@"
      ;;
    clear)
      shift
      clear_rules "${1:-}"
      ;;
    diagnose | diag)
      diagnose
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
