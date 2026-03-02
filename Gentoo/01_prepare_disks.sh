#!/usr/bin/env bash
set -euo pipefail

# =========================
# Phase 1: Disk Architecture
# Target disk: /dev/nvme0n1
# Layout:
#   p1: EFI (1G)  FAT32  mounted at /mnt/boot
#   p2: LUKS2 -> BTRFS with subvolumes
# =========================

DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
LUKS_PART="${DISK}p2"
CRYPT_NAME="cryptroot"
CRYPT_DEV="/dev/mapper/${CRYPT_NAME}"
BTRFS_LABEL="gentoo"

# Mount root for install
MNT="/mnt"

# BTRFS mount options (matching what you used)
ROOT_OPTS="noatime,compress=zstd:3,ssd,space_cache=v2"
SUBVOL_COMP_OPTS="noatime,compress=zstd:3,ssd,space_cache=v2"
SUBVOL_NOCOMP_OPTS="noatime,ssd,space_cache=v2"

SWAP_SIZE="16G"
SWAP_DIR="${MNT}/swap"
SWAP_FILE="${SWAP_DIR}/swapfile"

# -------------------------
# 0) Safety checks
# -------------------------
echo "[*] Target disk: ${DISK}"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS | sed -n '1,200p'
echo
echo "!!! WARNING: This will DESTROY ALL DATA on ${DISK} !!!"
read -r -p "Type WIPE to continue: " confirm
if [[ "${confirm}" != "WIPE" ]]; then
  echo "Aborted."
  exit 1
fi

# If rerunning, try to cleanly tear down old mounts and mappings
# -------------------------
# 1) Cleanup (best-effort)
# -------------------------
echo "[*] Best-effort cleanup (ignore errors)..."
swapoff "${SWAP_FILE}" 2>/dev/null || true
umount -R "${MNT}" 2>/dev/null || true
cryptsetup close "${CRYPT_NAME}" 2>/dev/null || true

# -------------------------
# 2) Partitioning (GPT + EFI + LUKS partition)
# -------------------------
echo "[*] Creating GPT + partitions..."
parted "${DISK}" --script mklabel gpt
parted "${DISK}" --script mkpart EFI fat32 1MiB 1025MiB
parted "${DISK}" --script set 1 esp on
parted "${DISK}" --script mkpart primary 1025MiB 100%

# Ensure kernel sees the new table
partprobe "${DISK}" || true

# Fix/relocate backup GPT if needed (safe even if not needed)
echo "[*] Ensuring GPT backup header is at end of disk..."
sgdisk -e "${DISK}"

echo "[*] Partition table:"
fdisk -l "${DISK}"

# -------------------------
# 3) LUKS2 setup
# -------------------------
echo "[*] Creating LUKS2 container on ${LUKS_PART}..."
cryptsetup luksFormat --type luks2 "${LUKS_PART}"

echo "[*] Opening LUKS container as ${CRYPT_NAME}..."
cryptsetup open "${LUKS_PART}" "${CRYPT_NAME}"

# -------------------------
# 4) BTRFS filesystem creation
# -------------------------
echo "[*] Creating BTRFS filesystem on ${CRYPT_DEV}..."
mkfs.btrfs -L "${BTRFS_LABEL}" "${CRYPT_DEV}"

# -------------------------
# 5) Create BTRFS subvolumes (temporary mount)
# -------------------------
echo "[*] Mounting top-level BTRFS to create subvolumes..."
mount "${CRYPT_DEV}" "${MNT}"

echo "[*] Creating subvolumes..."
btrfs subvolume create "${MNT}/@"
btrfs subvolume create "${MNT}/@home"
btrfs subvolume create "${MNT}/@root"
btrfs subvolume create "${MNT}/@var_log"
btrfs subvolume create "${MNT}/@var_cache"
btrfs subvolume create "${MNT}/@var_db"
btrfs subvolume create "${MNT}/@containers"
btrfs subvolume create "${MNT}/@vm"
btrfs subvolume create "${MNT}/@games"
btrfs subvolume create "${MNT}/@pkg"
btrfs subvolume create "${MNT}/@nvtmp"
btrfs subvolume create "${MNT}/@snapshots"
btrfs subvolume create "${MNT}/@swap"

echo "[*] Subvolumes created:"
btrfs subvolume list "${MNT}"

umount "${MNT}"

# -------------------------
# 6) Mount final subvolume layout
# -------------------------
echo "[*] Mounting root subvolume (@)..."
mount -o "${ROOT_OPTS},subvol=@ " "${CRYPT_DEV}" "${MNT}"

echo "[*] Creating mount points..."
mkdir -p \
  "${MNT}/boot" \
  "${MNT}/home" \
  "${MNT}/root" \
  "${MNT}/var/log" \
  "${MNT}/var/cache" \
  "${MNT}/var/db" \
  "${MNT}/containers" \
  "${MNT}/vm" \
  "${MNT}/games" \
  "${MNT}/pkg" \
  "${MNT}/nvtmp" \
  "${MNT}/.snapshots" \
  "${MNT}/swap"

echo "[*] Mounting remaining subvolumes..."
mount -o "${SUBVOL_COMP_OPTS},subvol=@home"      "${CRYPT_DEV}" "${MNT}/home"
mount -o "${SUBVOL_COMP_OPTS},subvol=@root"      "${CRYPT_DEV}" "${MNT}/root"
mount -o "${SUBVOL_COMP_OPTS},subvol=@var_log"   "${CRYPT_DEV}" "${MNT}/var/log"
mount -o "${SUBVOL_COMP_OPTS},subvol=@var_cache" "${CRYPT_DEV}" "${MNT}/var/cache"
mount -o "${SUBVOL_COMP_OPTS},subvol=@var_db"    "${CRYPT_DEV}" "${MNT}/var/db"
mount -o "${SUBVOL_COMP_OPTS},subvol=@games"     "${CRYPT_DEV}" "${MNT}/games"
mount -o "${SUBVOL_COMP_OPTS},subvol=@pkg"       "${CRYPT_DEV}" "${MNT}/pkg"
mount -o "${SUBVOL_COMP_OPTS},subvol=@nvtmp"     "${CRYPT_DEV}" "${MNT}/nvtmp"
mount -o "${SUBVOL_COMP_OPTS},subvol=@snapshots" "${CRYPT_DEV}" "${MNT}/.snapshots"

# "No compression" subvolumes (we'll enforce NOCOW with chattr +C)
mount -o "${SUBVOL_NOCOMP_OPTS},subvol=@containers" "${CRYPT_DEV}" "${MNT}/containers"
mount -o "${SUBVOL_NOCOMP_OPTS},subvol=@vm"         "${CRYPT_DEV}" "${MNT}/vm"
mount -o "${SUBVOL_NOCOMP_OPTS},subvol=@swap"       "${CRYPT_DEV}" "${MNT}/swap"

# -------------------------
# 7) Disable CoW where needed (must be done before writing data)
# -------------------------
echo "[*] Disabling CoW for containers and VM storage..."
chattr +C "${MNT}/containers"
chattr +C "${MNT}/vm"

# -------------------------
# 8) EFI filesystem and mount
# -------------------------
echo "[*] Formatting EFI partition as FAT32..."
mkfs.fat -F32 "${EFI_PART}"

echo "[*] Mounting EFI partition at ${MNT}/boot..."
mount "${EFI_PART}" "${MNT}/boot"

# -------------------------
# 9) Swapfile creation (BTRFS-safe: non-sparse)
# -------------------------
echo "[*] Creating swapfile (${SWAP_SIZE}) in ${SWAP_DIR}..."
cd "${SWAP_DIR}"

# Ensure NOCOW on directory, then allocate real blocks (no holes)
chattr +C .
rm -f "${SWAP_FILE}" || true
fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}"
chmod 600 "${SWAP_FILE}"

# Ensure compression off for swapfile (safe even if it errors on older tools)
btrfs property set "${SWAP_FILE}" compression none 2>/dev/null || true

mkswap "${SWAP_FILE}"
swapon "${SWAP_FILE}"

# -------------------------
# 10) Verification
# -------------------------
echo
echo "[*] Swap status:"
swapon --show || true

echo
echo "[*] BTRFS mounts:"
mount | grep btrfs || true

echo
echo "[*] Block devices:"
lsblk
echo
echo "[✓] Phase 1 complete."
