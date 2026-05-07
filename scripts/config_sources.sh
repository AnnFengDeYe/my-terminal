#!/usr/bin/env bash

select_ghostty_source() {
  local repo_root="$1"
  local os_name="$2"
  local macos_source="configs/ghostty/config"
  local linux_source="configs/ghostty/config.linux"

  case "$os_name" in
    macos)
      printf '%s\n' "$macos_source"
      ;;
    *)
      if [[ -e "$repo_root/$linux_source" || -L "$repo_root/$linux_source" ]]; then
        printf '%s\n' "$linux_source"
      else
        printf '%s\n' "$macos_source"
      fi
      ;;
  esac
}
