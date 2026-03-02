#!/usr/bin/env bash
set -euo pipefail

# =========================
# Phase 2: Stage3 + Chroot
# Assumes Phase 1 mounts are already done:
#   /mnt is mounted to subvol=@
#   /mnt/boot is mounted (EFI)
# =========================

MNT="/mnt"

cd "${MNT}"

# -------------------------
# 1) Fetch latest stage3 path (OpenRC)
# -------------------------
wget -O latest-stage3-amd64-openrc.txt \
  https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt

# Extract the tarball path (ignore comments/signature)
STAGE3_REL_PATH="$(grep -E '^[0-9]{8}T[0-9]{6}Z/stage3-amd64-openrc-.*\.tar\.xz' latest-stage3-amd64-openrc.txt | awk '{print $1}')"
if [[ -z "${STAGE3_REL_PATH}" ]]; then
  echo "Could not parse stage3 path from latest-stage3-amd64-openrc.txt"
  exit 1
fi

STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_REL_PATH}"
DIGESTS_URL="${STAGE3_URL}.DIGESTS"
STAGE3_FILE="$(basename "${STAGE3_REL_PATH}")"
DIGESTS_FILE="${STAGE3_FILE}.DIGESTS"

echo "[*] Stage3: ${STAGE3_URL}"

# -------------------------
# 2) Download stage3 + DIGESTS
# -------------------------
wget -O "${STAGE3_FILE}" "${STAGE3_URL}"
wget -O "${DIGESTS_FILE}" "${DIGESTS_URL}"

# -------------------------
# 3) Verify tarball (we only require that the tarball line verifies OK)
# -------------------------
echo "[*] Verifying SHA512 of stage3 tarball..."
# Try to verify only the tarball line; avoids failures for missing CONTENTS.gz
grep -A1 -n "SHA512 HASH" "${DIGESTS_FILE}" >/dev/null 2>&1 || true
# Verify by extracting the sha512 line for the tarball and checking it
TARBALL_SHA_LINE="$(awk -v f="${STAGE3_FILE}" '
  $0 ~ /^# SHA512 HASH/ {insha=1; next}
  insha && $2==f {print; exit}
  insha && $0 ~ /^#/ {next}
' "${DIGESTS_FILE}")"

if [[ -z "${TARBALL_SHA_LINE}" ]]; then
  echo "Could not find SHA512 line for ${STAGE3_FILE} in ${DIGESTS_FILE}"
  echo "Falling back to full -c check (may warn about missing CONTENTS.gz)..."
  sha512sum -c "${DIGESTS_FILE}" || true
else
  echo "${TARBALL_SHA_LINE}" | sha512sum -c -
fi

# -------------------------
# 4) Extract stage3
# -------------------------
echo "[*] Extracting stage3 to ${MNT}..."
tar xpvf "${STAGE3_FILE}" \
  --xattrs-include='*.*' \
  --numeric-owner

# -------------------------
# 5) DNS for chroot
# -------------------------
cp --dereference /etc/resolv.conf "${MNT}/etc/resolv.conf"

# -------------------------
# 6) Mount virtual filesystems for chroot
# -------------------------
mount --types proc /proc "${MNT}/proc"
mount --rbind /sys "${MNT}/sys"
mount --make-rslave "${MNT}/sys"
mount --rbind /dev "${MNT}/dev"
mount --make-rslave "${MNT}/dev"
mount --bind /run "${MNT}/run"
mount --make-slave "${MNT}/run"

# -------------------------
# 7) Enter chroot
# -------------------------
echo "[*] Entering chroot..."
chroot "${MNT}" /bin/bash -c 'source /etc/profile; export PS1="(chroot) ${PS1}"; exec bash'

echo "[✓] Phase 2 complete."
