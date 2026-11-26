#!/usr/bin/env bash
# Base step 2: a swap file sized from RAM. Sourced, never executed.

# swap_size_gib <MemTotal in kB>: RAM rounded up to whole GiB (a "1 GiB" VPS reports
# slightly less), then up to 2 GiB swap equals RAM, above that half of it, capped at 4.
swap_size_gib() {
  local ram=$(( ($1 + 1048575) / 1048576 )) size
  if [ "$ram" -le 2 ]; then
    size=$ram
  elif [ "$ram" -le 4 ]; then
    size=2
  else
    size=$(( ram / 2 ))
  fi
  [ "$size" -gt 4 ] && size=4
  echo "$size"
}

base_swap() {
  local file kb size fstab
  file="$(p /swapfile)"
  fstab="$(p /etc/fstab)"
  kb="$(awk '/^MemTotal:/ {print $2}' "$(p /proc/meminfo)")"
  size="$(swap_size_gib "$kb")"

  if [ ! -e "$file" ]; then
    # Build under a temporary name so a crash never leaves a half-made /swapfile.
    fallocate -l "${size}G" "$file.tmp"
    chmod 600 "$file.tmp"
    mkswap "$file.tmp"
    mv -f "$file.tmp" "$file"
  fi
  mkdir -p "$(dirname "$fstab")"
  touch "$fstab"
  grep -qE '^/swapfile[[:space:]]' "$fstab" || echo '/swapfile none swap sw 0 0' >>"$fstab"
  swapon --show=NAME --noheadings | grep -qx "$file" || swapon "$file"
}
