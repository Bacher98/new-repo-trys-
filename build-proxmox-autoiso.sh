#!/usr/bin/env bash
set -euo pipefail

PVE_VERSION="9.2-1"
ISO_NAME="proxmox-ve_${PVE_VERSION}.iso"
ISO_URL="https://download.proxmox.com/iso/${ISO_NAME}"
ISO_SHA256="4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c"

WORKDIR="${PWD}/pve-auto-build"
OUT_ISO="${WORKDIR}/proxmox-ve-${PVE_VERSION}-dell5810-auto.iso"
ANSWER="${WORKDIR}/answer.toml"

FQDN="${FQDN:-pve-dell5810.local}"
TARGET_DISK="${TARGET_DISK:-sda}"
MAILTO="${MAILTO:-root@local}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

# ==================== CI / NON-INTERACTIVE MODE ====================
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "=== Running in GitHub Actions ==="
  ROOT_PASSWORD="${ROOT_PASSWORD:-changeme123!}"
  ROOT_HASH="$(openssl passwd -6 "$ROOT_PASSWORD")"
  export ROOT_HASH
  unset ROOT_PASSWORD
  echo "✓ CI-Mode: Passwort-Hash gesetzt (Default: changeme123!)"
else
  # Interaktiver Modus (lokal)
  create_password_hash() {
    echo "=== Root-Passwort für Proxmox setzen ==="
    while true; do
      read -r -s -p "Passwort: " ROOT_PASS
      echo
      read -r -s -p "Passwort wiederholen: " ROOT_PASS2
      echo
      if [ "$ROOT_PASS" = "$ROOT_PASS2" ] && [ -n "$ROOT_PASS" ]; then
        ROOT_HASH="$(openssl passwd -6 "$ROOT_PASS")"
        export ROOT_HASH
        unset ROOT_PASS ROOT_PASS2
        echo "✓ Passwort gesetzt und gehasht."
        return 0
      fi
      echo "❌ Passwörter stimmen nicht überein oder sind leer. Bitte erneut versuchen."
    done
  }
fi

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Dieses Script bitte mit sudo/root ausführen."
    exit 1
  fi
}

install_deps() {
  apt-get update
  apt-get install -y wget curl gpg openssl xorriso debootstrap squashfs-tools ca-certificates

  if ! command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
    . /etc/os-release

    if [ "${VERSION_CODENAME:-}" = "trixie" ]; then
      echo "deb [arch=amd64] http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
        > /etc/apt/sources.list.d/pve-install-repo.list
      wget -qO - https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
        | gpg --dearmor > /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg
    elif [ "${VERSION_CODENAME:-}" = "bookworm" ]; then
      echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
        > /etc/apt/sources.list.d/pve-install-repo.list
      wget -qO - https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
        | gpg --dearmor > /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
    else
      echo "Nicht unterstützte Basis: ${PRETTY_NAME:-unknown}"
      echo "Nutze Debian 12 (bookworm) oder 13 (trixie)."
      exit 1
    fi

    apt-get update
    apt-get install -y proxmox-auto-install-assistant
  fi
}

download_iso() {
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  if [ ! -f "$ISO_NAME" ]; then
    echo "Lade Proxmox ISO herunter..."
    wget -O "$ISO_NAME" "$ISO_URL"
  fi

  echo "${ISO_SHA256}  ${ISO_NAME}" | sha256sum -c -
  echo "✓ ISO erfolgreich verifiziert."
}

create_answer() {
  SSH_KEYS_BLOCK=""

  if [ -f "$SSH_KEY_FILE" ]; then
    SSH_PUB="$(cat "$SSH_KEY_FILE")"
    SSH_KEYS_BLOCK=$(cat <<KEYS
root-ssh-keys = [
  "${SSH_PUB}"
]
KEYS
)
  fi

  cat > "$ANSWER" <<TOML
[global]
keyboard = "de"
country = "de"
fqdn = "${FQDN}"
mailto = "${MAILTO}"
timezone = "Europe/Berlin"
root-password-hashed = "${ROOT_HASH}"
reboot-mode = "reboot"
${SSH_KEYS_BLOCK}

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk-list = ["${TARGET_DISK}"]

[first-boot]
source = "from-iso"
ordering = "fully-up"
TOML
}

create_firstboot() {
  cat > "${WORKDIR}/firstboot.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

LOG="/var/log/proxmox-firstboot-custom.log"
exec > >(tee -a "$LOG") 2>&1

echo "[+] First boot bootstrap started"

PVE_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

echo "[+] Configure no-subscription repo"
rm -f /etc/apt/sources.list.d/pve-enterprise.list
cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve ${PVE_CODENAME} pve-no-subscription
EOF

echo "[+] Base packages"
apt-get update
apt-get install -y \
  curl git htop iftop iotop smartmontools lm-sensors \
  vim nano sudo pciutils usbutils lshw ethtool \
  prometheus-node-exporter

echo "[+] Enable useful services"
systemctl enable --now prometheus-node-exporter
systemctl enable --now fstrim.timer || true

echo "[+] IOMMU/VFIO base prep for future GPU passthrough"
if grep -qi intel /proc/cpuinfo; then
  IOMMU_FLAGS="intel_iommu=on iommu=pt"
elif grep -qi amd /proc/cpuinfo; then
  IOMMU_FLAGS="amd_iommu=on iommu=pt"
else
  IOMMU_FLAGS="iommu=pt"
fi

if [ -f /etc/default/grub ]; then
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet ${IOMMU_FLAGS}\"/" /etc/default/grub
  else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet ${IOMMU_FLAGS}\"" >> /etc/default/grub
  fi
  update-grub || true
fi

cat > /etc/modules-load.d/vfio.conf <<EOF
vfio
vfio_iommu_type1
vfio_pci
EOF

echo "[+] Tailscale install only; login/enrollment later"
curl -fsSL https://tailscale.com/install.sh | sh || true
systemctl enable --now tailscaled || true

echo "[+] Dell 5810 performance defaults"
cat > /etc/sysctl.d/99-homelab-performance.conf <<EOF
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
fs.file-max=2097152
net.core.somaxconn=65535
EOF

sysctl --system || true

echo "[+] First boot bootstrap finished"
echo "Reboot empfohlen für IOMMU/Kernel-Parameter."
SCRIPT

  chmod +x "${WORKDIR}/firstboot.sh"
}

validate_and_build() {
  proxmox-auto-install-assistant validate-answer "$ANSWER"

  proxmox-auto-install-assistant prepare-iso \
    --fetch-from iso \
    --answer-file "$ANSWER" \
    --on-first-boot "${WORKDIR}/firstboot.sh" \
    --output "$OUT_ISO" \
    "${WORKDIR}/${ISO_NAME}"

  echo
  echo "Fertig:"
  echo "$OUT_ISO"
}

main() {
  need_root
  install_deps
  if [ -z "${ROOT_HASH:-}" ]; then
    create_password_hash
  fi
  download_iso
  create_answer
  create_firstboot
  validate_and_build
}

main "$@"
