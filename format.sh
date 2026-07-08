#!/usr/bin/env bash
# Partition formatter for NixOS fresh installs.
# Interactively selects and formats EFI, root, and (optionally) swap partitions.
#
# Usage: ./format.sh

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  RED='\033[0;31m'
  GRN='\033[0;32m'
  YLW='\033[0;33m'
  BLU='\033[0;34m'
  CYN='\033[0;36m'
  RST='\033[0m'
else
  BOLD='' DIM='' RED='' GRN='' YLW='' BLU='' CYN='' RST=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
die()  { echo -e "${RED}error:${RST} $*" >&2; exit 1; }
warn() { echo -e "${YLW}warning:${RST} $*" >&2; }
info() { echo -e "${CYN}==>${RST} ${BOLD}$*${RST}"; }
ok()   { echo -e "${GRN} ✓${RST} $*"; }

hr() {
  local width="${COLUMNS:-80}"
  printf "${DIM}%${width}s${RST}\n" '' | tr ' ' '─'
}

# ── Preflight ─────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "must be run as root"

for cmd in lsblk mkfs.fat mkfs.ext4 mkswap blkid; do
  command -v "$cmd" &>/dev/null || die "required tool not found: $cmd"
done

# ── Partition listing ─────────────────────────────────────────────────────────
# Returns an array of partition block devices (not whole disks)
get_parts() {
  lsblk -lnpo NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINT \
    | awk '$2 == "part" || $2 == "lvm" { print $0 }' \
    | sort
}

# Pretty-prints the partition table for reference
show_disk_layout() {
  echo
  echo -e "${BOLD}  Disk layout:${RST}"
  hr
  printf "${BOLD}  %-22s %-6s %-8s %-12s %-16s %s${RST}\n" \
    "DEVICE" "TYPE" "SIZE" "FSTYPE" "LABEL" "MOUNTPOINT"
  hr
  lsblk -lnpo NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINT | while read -r line; do
    dev=$(awk '{print $1}' <<< "$line")
    type=$(awk '{print $2}' <<< "$line")
    rest=$(cut -d' ' -f3- <<< "$line")
    case "$type" in
      disk) echo -e "  ${BLU}${BOLD}${dev}${RST}  ${DIM}${rest}${RST}" ;;
      part) echo -e "  ${CYN}  ${dev}${RST}  ${rest}" ;;
      lvm)  echo -e "  ${YLW}  ${dev}${RST}  ${rest}" ;;
      *)    echo -e "  ${DIM}  ${dev}  ${rest}${RST}" ;;
    esac
  done
  hr
  echo
}

# Build a numbered menu of partitions and prompt user to pick one.
# Usage: pick_partition <prompt> [allow_none]
# Prints chosen device to stdout; returns 1 if "none" selected.
pick_partition() {
  local prompt="$1"
  local allow_none="${2:-}"

  # Collect partitions into an array
  local parts=()
  while IFS= read -r line; do
    parts+=("$line")
  done < <(get_parts)

  if [ "${#parts[@]}" -eq 0 ]; then
    die "no partitions found — partition the disk first (use fdisk, gdisk, or parted)"
  fi

  echo -e "${BOLD}  ${prompt}${RST}"
  echo

  local i=1
  for line in "${parts[@]}"; do
    local dev size fstype label mount
    dev=$(awk '{print $1}' <<< "$line")
    size=$(awk '{print $3}' <<< "$line")
    fstype=$(awk '{print $4}' <<< "$line")
    label=$(awk '{print $5}' <<< "$line")
    mount=$(awk '{print $6}' <<< "$line")

    [ "$fstype" = "-" ] && fstype=""
    [ "$label"  = "-" ] && label=""
    [ "$mount"  = "-" ] && mount=""

    local meta=""
    [ -n "$fstype" ] && meta+="${fstype}"
    [ -n "$label"  ] && meta+=" \"${label}\""
    [ -n "$mount"  ] && meta+=" → ${mount}"
    [ -n "$meta"   ] && meta=" ${DIM}(${meta})${RST}"

    printf "    ${YLW}[%2d]${RST}  %-22s ${GRN}%6s${RST}%b\n" \
      "$i" "$dev" "$size" "$meta"
    (( i++ ))
  done

  if [ -n "$allow_none" ]; then
    printf "    ${DIM}[ 0]  skip / none${RST}\n"
  fi

  echo
  local choice
  while true; do
    read -rp "    Enter number: " choice
    if [ -n "$allow_none" ] && [ "$choice" = "0" ]; then
      echo ""   # signal: none
      return 1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#parts[@]}" ]; then
      awk '{print $1}' <<< "${parts[$((choice-1))]}"
      return 0
    fi
    warn "invalid selection — enter a number between 1 and ${#parts[@]}${allow_none:+ (or 0 to skip)}"
  done
}

# ── Root filesystem selection ─────────────────────────────────────────────────
pick_fstype() {
  echo -e "${BOLD}  Root filesystem type:${RST}"
  echo
  echo -e "    ${YLW}[ 1]${RST}  ext4   ${DIM}(stable, widely supported)${RST}"
  echo -e "    ${YLW}[ 2]${RST}  btrfs  ${DIM}(snapshots, compression, subvolumes)${RST}"
  echo -e "    ${YLW}[ 3]${RST}  xfs    ${DIM}(high performance, large files)${RST}"
  echo

  local choice
  while true; do
    read -rp "    Enter number [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
      1) echo "ext4";  return ;;
      2) echo "btrfs"; return ;;
      3) echo "xfs";   return ;;
      *) warn "invalid selection — enter 1, 2, or 3" ;;
    esac
  done
}

# ── Confirmation ──────────────────────────────────────────────────────────────
confirm() {
  local answer
  read -rp "$* [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${BLU}  NixOS Partition Formatter${RST}"
echo -e "  ${DIM}Formats EFI, root, and swap partitions for a fresh install.${RST}"

show_disk_layout

# --- EFI partition ---
info "Select EFI (boot) partition"
EFI_PART="$(pick_partition "Which partition should be the EFI system partition? (will be formatted FAT32)")"
echo

# --- Root partition ---
info "Select root filesystem partition"
ROOT_PART="$(pick_partition "Which partition should be the root filesystem?")"
echo

ROOT_FS="$(pick_fstype)"
echo

# --- Swap partition (optional) ---
info "Select swap partition  ${DIM}(optional — enter 0 to skip)${RST}"
SWAP_PART=""
if pick_partition "Which partition should be swap?" "allow_none" > /tmp/_fmt_swap 2>&1; then
  SWAP_PART="$(cat /tmp/_fmt_swap)"
fi
rm -f /tmp/_fmt_swap
echo

# --- Sanity: ensure no duplicates ---
check_unique() {
  local -A seen
  for p in "$@"; do
    [ -z "$p" ] && continue
    [ -n "${seen[$p]:-}" ] && die "partition selected more than once: $p"
    seen[$p]=1
  done
}
check_unique "$EFI_PART" "$ROOT_PART" "${SWAP_PART:-}"

# --- Summary + confirm ---
hr
echo -e "${BOLD}  Format plan:${RST}"
echo
printf "  %-10s  %-22s  %s\n" "Role" "Device" "Action"
hr
printf "  ${GRN}%-10s${RST}  %-22s  %s\n" "EFI"  "$EFI_PART"  "mkfs.fat -F32 -n EFI"
printf "  ${GRN}%-10s${RST}  %-22s  %s\n" "Root" "$ROOT_PART" "mkfs.${ROOT_FS}"
if [ -n "$SWAP_PART" ]; then
  printf "  ${GRN}%-10s${RST}  %-22s  %s\n" "Swap" "$SWAP_PART" "mkswap"
else
  printf "  ${DIM}%-10s  %-22s  %s${RST}\n"  "Swap" "(none)" "skipped"
fi
hr
echo
warn "This will ${BOLD}PERMANENTLY DESTROY${RST}${YLW} all data on the selected partitions."
echo

confirm "  Proceed with formatting?" || { echo "Aborted."; exit 0; }
echo

# --- Format ---
info "Formatting EFI partition: $EFI_PART"
mkfs.fat -F32 -n EFI "$EFI_PART"
ok "EFI partition formatted (FAT32)"

info "Formatting root partition: $ROOT_PART  (${ROOT_FS})"
case "$ROOT_FS" in
  ext4)  mkfs.ext4  -L nixos "$ROOT_PART" ;;
  btrfs) mkfs.btrfs -L nixos "$ROOT_PART" ;;
  xfs)   mkfs.xfs   -L nixos "$ROOT_PART" ;;
esac
ok "Root partition formatted (${ROOT_FS}, label: nixos)"

if [ -n "$SWAP_PART" ]; then
  info "Formatting swap partition: $SWAP_PART"
  mkswap -L swap "$SWAP_PART"
  ok "Swap partition formatted"
fi

echo
ok "All done. Next: mount the partitions and run bootstrap.sh."
echo -e "  ${DIM}Example:${RST}"
echo -e "  ${DIM}  mount $ROOT_PART /mnt${RST}"
echo -e "  ${DIM}  mkdir -p /mnt/boot && mount $EFI_PART /mnt/boot${RST}"
[ -n "$SWAP_PART" ] && \
  echo -e "  ${DIM}  swapon $SWAP_PART${RST}"
echo
