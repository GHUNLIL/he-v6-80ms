#!/usr/bin/env bash
set -Eeuo pipefail

# Public reusable launcher for this repository.

SCRIPT_VERSION="2026-05-19.1"
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/GHUNLIL/he-v6-80ms/main}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

SCRIPTS=(
  "aws-wg-phantun-server.sh"
  "mkcloud-wg-phantun-client.sh"
  "mkcloud-nft-port-forward.sh"
  "linux-game-qos.sh"
  "mkcloud-fix-nft-wg-snat.sh"
)

log() {
  printf '\033[1;32m[INFO]\033[0m %s\n' "$*" >&2
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

pause_ui() {
  local _
  read_tty _ "按回车返回菜单..."
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
      printf '   %s\n' "${title}"
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

ensure_script() {
  local script="$1"
  local path="${SCRIPT_DIR}/${script}"

  if [[ -f "${path}" ]]; then
    chmod +x "${path}" >/dev/null 2>&1 || true
    printf '%s\n' "${path}"
    return
  fi

  command -v curl >/dev/null 2>&1 || fatal "缺少 curl，无法下载 ${script}。"
  log "下载 ${script}。"
  curl -fsSL "${REPO_RAW_BASE}/${script}" -o "${path}"
  chmod +x "${path}"
  printf '%s\n' "${path}"
}

run_script() {
  local script="$1"
  local path

  path="$(ensure_script "${script}")"
  bash "${path}"
}

print_commands() {
  cat <<EOF

公开拉取命令：

入口菜单：
  sudo bash -c "\$(curl -fsSL ${REPO_RAW_BASE}/start.sh)"

AWS 服务端：
  sudo bash -c "\$(curl -fsSL ${REPO_RAW_BASE}/aws-wg-phantun-server.sh)"

MK 客户端：
  sudo bash -c "\$(curl -fsSL ${REPO_RAW_BASE}/mkcloud-wg-phantun-client.sh)"

MK 端口转发：
  sudo bash -c "\$(curl -fsSL ${REPO_RAW_BASE}/mkcloud-nft-port-forward.sh)"

游戏 QoS：
  sudo bash -c "\$(curl -fsSL ${REPO_RAW_BASE}/linux-game-qos.sh)"

SNAT 修复工具：
  sudo bash -c "\$(curl -fsSL ${REPO_RAW_BASE}/mkcloud-fix-nft-wg-snat.sh)"

EOF
}

main_menu() {
  while true; do
    choose_menu "HE IPv6 / WireGuard / Phantun 工具箱" \
      "AWS 服务端：WireGuard + Phantun" \
      "MK 客户端：WireGuard + Phantun" \
      "MK 端口转发：nftables 范围转发" \
      "Linux QoS：游戏优先，总带宽限制" \
      "MK SNAT 修复工具" \
      "显示公开拉取命令" \
      "退出" || exit 1

    case "${MENU_CHOICE}" in
      0) run_script "${SCRIPTS[0]}"; pause_ui ;;
      1) run_script "${SCRIPTS[1]}"; pause_ui ;;
      2) run_script "${SCRIPTS[2]}"; pause_ui ;;
      3) run_script "${SCRIPTS[3]}"; pause_ui ;;
      4) run_script "${SCRIPTS[4]}"; pause_ui ;;
      5) print_commands; pause_ui ;;
      6) exit 0 ;;
    esac
  done
}

main_menu "$@"
