#!/usr/bin/env bash
set -euo pipefail

main() {
  local kernel
  kernel="$(uname -s 2>/dev/null || true)"

  case "$kernel" in
    Darwin)
      printf '%s\n' "macos"
      return 0
      ;;
    Linux)
      detect_linux
      return 0
      ;;
    *)
      printf '%s\n' "unknown"
      return 0
      ;;
  esac
}

detect_linux() {
  local id=""
  local id_like=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
    id_like="${ID_LIKE:-}"
  fi

  case "$id" in
    debian)
      printf '%s\n' "debian"
      ;;
    ubuntu)
      printf '%s\n' "ubuntu"
      ;;
    raspbian)
      printf '%s\n' "raspberrypi"
      ;;
    arch)
      printf '%s\n' "arch"
      ;;
    fedora)
      printf '%s\n' "fedora"
      ;;
    *)
      case " $id_like " in
        *" debian "*)
          printf '%s\n' "debian"
          ;;
        *" arch "*)
          printf '%s\n' "arch"
          ;;
        *" fedora "*|*" rhel "*)
          printf '%s\n' "fedora"
          ;;
        *)
          printf '%s\n' "unknown-linux"
          ;;
      esac
      ;;
  esac
}

main "$@"
