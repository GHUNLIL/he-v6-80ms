#!/usr/bin/env bash
set -Eeuo pipefail

# 修复 MKCloud 上 nftables 端口转发的回程 SNAT。
# 场景：本机端口 DNAT 到 WireGuard 目标，例如 4.4.4.1:8080。
# 正确回程必须 SNAT 为到目标的路由源地址，例如 4.4.4.2，而不是公网/内网出口 IP。

CONF_FILE="${CONF_FILE:-/etc/nftables.d/port-forward.conf}"
TABLE_NAME="${TABLE_NAME:-port_forward}"

log() {
  printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}

fatal() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
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
  ip6tables -C INPUT -p tcp --sport 44445 -j DROP 2>/dev/null \
    || ip6tables -I INPUT -p tcp --sport 44445 -j DROP
}

main() {
  require_root
  command -v nft >/dev/null 2>&1 || fatal "nft 命令不存在，请先安装 nftables。"
  rewrite_conf
  restore_phantun_rst_guard
  log "已修复 ${CONF_FILE} 并加载 nftables。当前规则："
  nft list table ip "${TABLE_NAME}"
  log "已恢复 Phantun FakeTCP RST 防护：ip6tables INPUT tcp --sport 44445 DROP。"
}

main "$@"
