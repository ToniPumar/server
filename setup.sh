#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================
#  setup_basico_granxa_v2.3.sh
#  - Base Ubuntu Server para Granxa Pumar
#  - Idempotente y con flags non-interactive
#  - Docker + Compose, UFW, SSH endurecido
#  - Tailscale, sysctl, unattended-upgrades
#  - Coral PCIe (opcional) -> ahora se puede saltar
#  - Frigate DIR configurable, disco opcional
# ==========================================

LOG_FILE="/var/log/setup_basico_granxa.log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "[ERROR] Fallo en línea $LINENO. Revisa $LOG_FILE"' ERR

# ---------- Defaults ----------
DEFAULT_HOSTNAME="granxa-server"
LAN_CIDR=""
NON_INTERACTIVE="false"

INSTALL_COCKPIT="N"
INSTALL_NETDATA="N"
FORCE_SSH_PASSWORD="N"     # habilitar PasswordAuthentication temporalmente
SET_TONI_PASS="S"          # pedir contraseña a 'toni' si falta

TAILSCALE_AUTHKEY=""

# Coral (NUEVO): permitir saltar la instalación
SKIP_CORAL="N"             # S/N o yes/no

# Frigate
FRIGATE_DIR="/srv/media/frigate"
DISK2_DEV=""               # ej. sdb o nvme1n1
FORCE_FORMAT="no"          # yes/no: solo si pasas --frigate-disk

# ---------- Ayuda ----------
print_help() {
  cat <<EOF
Uso: sudo ./setup_basico_granxa_v2.3.sh [opciones]

Generales:
  --non-interactive            Ejecutar sin preguntas
  --hostname HOST              Hostname (default ${DEFAULT_HOSTNAME})
  --lan-cidr CIDR              Rango LAN para SSH/Cockpit (ej. 192.168.1.0/24)

Acceso y admin:
  --ssh-password yes|no        Habilitar PasswordAuthentication temporalmente (default no)
  --set-toni-pass yes|no       Pedir y poner contraseña a 'toni' (default yes)
  --cockpit yes|no             Instalar Cockpit (default no)
  --netdata yes|no             Instalar Netdata (default no)

Tailscale:
  --tailscale-authkey KEY      Auth key para alta automática (opcional)

Coral:
  --skip-coral yes|no          Saltar instalación de Coral/EDGETPU (default no)

Frigate (ruta y disco de datos):
  --frigate-dir PATH           Ruta de datos de Frigate (default ${FRIGATE_DIR})
  --frigate-disk DEV           Disco a preparar (ej. sdb, nvme1n1). Si no lo pones, no toca discos.
  --force-format yes|no        Forzar formateo si el disco no es ext4 (default no)

Ayuda:
  -h | --help                  Mostrar esta ayuda
EOF
}

# ---------- Parseo de flags ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE="true"; shift;;
    --hostname) DEFAULT_HOSTNAME="$2"; shift 2;;
    --lan-cidr) LAN_CIDR="$2"; shift 2;;

    --ssh-password) FORCE_SSH_PASSWORD=$([[ "$2" =~ ^(?i)(y|yes|s|si)$ ]] && echo "S" || echo "N"); shift 2;;
    --set-toni-pass) SET_TONI_PASS=$([[ "$2" =~ ^(?i)(y|yes|s|si)$ ]] && echo "S" || echo "N"); shift 2;;
    --cockpit) INSTALL_COCKPIT=$([[ "$2" =~ ^(?i)(y|yes|s|si)$ ]] && echo "S" || echo "N"); shift 2;;
    --netdata) INSTALL_NETDATA=$([[ "$2" =~ ^(?i)(y|yes|s|si)$ ]] && echo "S" || echo "N"); shift 2;;

    --tailscale-authkey) TAILSCALE_AUTHKEY="$2"; shift 2;;

    --skip-coral) SKIP_CORAL=$([[ "$2" =~ ^(?i)(y|yes|s|si)$ ]] && echo "S" || echo "N"); shift 2;;

    --frigate-dir) FRIGATE_DIR="$2"; shift 2;;
    --frigate-disk) DISK2_DEV="$2"; shift 2;;
    --force-format) FORCE_FORMAT="$2"; shift 2;;

    -h|--help) print_help; exit 0;;
    *) echo "Opción desconocida: $1"; print_help; exit 1;;
  esac
done

# ---------- Interactivo si no se pasa --non-interactive ----------
if [[ "$NON_INTERACTIVE" != "true" ]]; then
  read -rp "Hostname del servidor [${DEFAULT_HOSTNAME}]: " NEW_HOSTNAME
  NEW_HOSTNAME=${NEW_HOSTNAME:-$DEFAULT_HOSTNAME}

  read -rp "CIDR de tu LAN (ej. 192.168.1.0/24): " LAN_CIDR_IN
  LAN_CIDR=${LAN_CIDR:-$LAN_CIDR_IN}

  read -rp "¿Instalar Cockpit? [s/N]: " INSTALL_COCKPIT_IN; INSTALL_COCKPIT=${INSTALL_COCKPIT_IN:-$INSTALL_COCKPIT}
  read -rp "¿Instalar Netdata? [s/N]: " INSTALL_NETDATA_IN; INSTALL_NETDATA=${INSTALL_NETDATA_IN:-$INSTALL_NETDATA}
  read -rp "¿Forzar PasswordAuthentication en SSH por ahora? [s/N]: " FORCE_SSH_PASSWORD_IN; FORCE_SSH_PASSWORD=${FORCE_SSH_PASSWORD_IN:-$FORCE_SSH_PASSWORD}

  read -rp "Ruta de Frigate [${FRIGATE_DIR}]: " FRIGATE_DIR_IN
  FRIGATE_DIR=${FRIGATE_DIR_IN:-$FRIGATE_DIR}

  echo "La ruta de Frigate quedará en: ${FRIGATE_DIR}"
  read -rp "¿Preparar un disco para montar en esa ruta ahora? (vacío para omitir, ej. sdb o nvme1n1): " DISK2_DEV_IN
  DISK2_DEV=${DISK2_DEV:-$DISK2_DEV_IN}
  if [[ -n "$DISK2_DEV" ]]; then
    read -rp "Si no es ext4, ¿forzar formateo? [y/N]: " FF; [[ "${FF:-N}" =~ ^[Yy]$ ]] && FORCE_FORMAT="yes" || FORCE_FORMAT="no"
  fi

  read -rp "¿Saltar instalación de Coral ahora? (recomendado S si dio error antes) [S/n]: " SKIP_CORAL_IN
  SKIP_CORAL=${SKIP_CORAL_IN:-S}

  read -rp "¿Configurar contraseña para 'toni'? [S/n]: " SET_TONI_PASS_IN; SET_TONI_PASS=${SET_TONI_PASS_IN:-$SET_TONI_PASS}
  if [[ "$SET_TONI_PASS" =~ ^[Ss]$ ]]; then
    while true; do
      read -srp "Nueva contraseña para 'toni': " P1; echo
      read -srp "Repite la contraseña: " P2; echo
      [[ "$P1" == "$P2" ]] && break || echo "No coinciden. Intenta de nuevo."
    done
  fi

  read -rp "Auth Key Tailscale (opcional): " TAILSCALE_AUTHKEY_IN
  TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY:-$TAILSCALE_AUTHKEY_IN}
else
  NEW_HOSTNAME="$DEFAULT_HOSTNAME"
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Ejecuta como root: sudo ./setup_basico_granxa_v2.3.sh"
  exit 1
fi

echo "==> Hostname: ${NEW_HOSTNAME:-$DEFAULT_HOSTNAME}"
echo "==> LAN CIDR: ${LAN_CIDR:-none}"
echo "==> Frigate DIR: ${FRIGATE_DIR}"
echo "==> Disco Frigate: ${DISK2_DEV:-omitido} | force-format: ${FORCE_FORMAT}"
echo "==> Saltar Coral: ${SKIP_CORAL}"

# ---------- Hostname y zona horaria ----------
hostnamectl set-hostname "${NEW_HOSTNAME:-$DEFAULT_HOSTNAME}"
timedatectl set-timezone Europe/Madrid
timedatectl set-ntp true

# ---------- Actualización del sistema ----------
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade
apt-get -y autoremove --purge
apt-get -y autoclean

# ---------- Paquetes base ----------
apt-get install -y \
  ca-certificates curl gnupg lsb-release software-properties-common \
  build-essential dkms linux-headers-$(uname -r) \
  apt-transport-https wget git unzip vim tmux htop iotop net-tools ufw \
  smartmontools nvme-cli jq openssh-server

# ---------- Unattended upgrades finos ----------
apt-get install -y unattended-upgrades update-notifier-common
cat >/etc/apt/apt.conf.d/51unattended-upgrades-granxa <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::OnlyOnACPower "false";
Unattended-Upgrade::InstallOnShutdown "true";
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
};
EOF
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades || true

# ---------- Usuario 'toni' ----------
if ! id "toni" &>/dev/null; then
  adduser --disabled-password --gecos "" toni
fi
usermod -aG sudo,plugdev,dialout toni || true
if [[ "$SET_TONI_PASS" =~ ^[Ss]$ && -n "${P1:-}" ]]; then
  echo "toni:${P1}" | chpasswd
fi

# Claves SSH para toni si no existen (opcional)
if [[ ! -f /home/toni/.ssh/authorized_keys ]]; then
  mkdir -p /home/toni/.ssh
  chmod 700 /home/toni/.ssh
  touch /home/toni/.ssh/authorized_keys
  chmod 600 /home/toni/.ssh/authorized_keys
  chown -R toni:toni /home/toni/.ssh
  echo "# Pega aquí tu clave pública si algún día quieres usarla" >> /home/toni/.ssh/authorized_keys
fi

# ---------- Docker + Compose ----------
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# Docker daemon.json con rotación de logs y cgroupdriver=systemd
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m", "max-file": "3" },
  "exec-opts": ["native.cgroupdriver=systemd"],
  "iptables": true,
  "ipv6": false
}
EOF
systemctl restart docker
usermod -aG docker toni || true

# ---------- Sysctl útiles ----------
cat >/etc/sysctl.d/90-granxa.conf <<'EOF'
fs.inotify.max_user_instances=2048
fs.inotify.max_user_watches=1048576
vm.swappiness=10
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.tcp_syncookies=1
EOF
sysctl --system

# ---------- Tailscale ----------
curl -fsSL https://tailscale.com/install.sh | sh
if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
  tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh || true
else
  echo "[INFO] Tailscale instalado. Ejecuta 'sudo tailscale up --ssh' para iniciar sesión."
fi

# ---------- UFW ----------
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Permitir Tailscale siempre
ufw allow in on tailscale0

# SSH limitado: tailscale y LAN
ufw limit 22/tcp
if [[ -n "$LAN_CIDR" ]]; then
  ufw allow from "$LAN_CIDR" to any port 22 proto tcp
fi

# Cockpit si procede
if [[ "$INSTALL_COCKPIT" =~ ^[Ss]$ ]]; then
  apt-get install -y cockpit
  systemctl enable --now cockpit.socket
  ufw allow in on tailscale0 to any port 9090 proto tcp
  if [[ -n "$LAN_CIDR" ]]; then
    ufw allow from "$LAN_CIDR" to any port 9090 proto tcp
  fi
fi

ufw --force enable

# ---------- SSH endurecido ----------
SSHD="/etc/ssh/sshd_config"
[[ ! -f ${SSHD}.bak ]] && cp "$SSHD" "${SSHD}.bak"

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/g' "$SSHD"
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$SSHD"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/g' "$SSHD"
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/g' "$SSHD"
sed -i 's/^#\?UsePAM.*/UsePAM yes/g' "$SSHD"
grep -q '^AllowUsers toni' "$SSHD" || echo 'AllowUsers toni' >> "$SSHD"
grep -q '^LoginGraceTime' "$SSHD" || echo 'LoginGraceTime 20' >> "$SSHD"
grep -q '^MaxAuthTries' "$SSHD" || echo 'MaxAuthTries 3' >> "$SSHD"
grep -q '^ClientAliveInterval' "$SSHD" || echo 'ClientAliveInterval 300' >> "$SSHD"
grep -q '^ClientAliveCountMax' "$SSHD" || echo 'ClientAliveCountMax 2' >> "$SSHD"
grep -q '^UseDNS' "$SSHD" || echo 'UseDNS no' >> "$SSHD"

if [[ "$FORCE_SSH_PASSWORD" =~ ^[Ss]$ ]]; then
  sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/g' "$SSHD"
  echo "[WARN] SSH con contraseña habilitado temporalmente."
fi

systemctl restart ssh || systemctl restart sshd || true

# ---------- Coral PCIe (OPCIONAL / SALTAR) ----------
if [[ "$SKIP_CORAL" =~ ^[SsYy]$ ]]; then
  echo "[INFO] Saltando instalación de Coral (gasket-dkms/libedgetpu1-std)."
else
  # Repo Coral con keyrings (evita apt-key deprecated)
  if [[ ! -f /etc/apt/keyrings/coral.gpg ]]; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/coral.gpg
  fi
  echo "deb [signed-by=/etc/apt/keyrings/coral.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main" \
    > /etc/apt/sources.list.d/coral-edgetpu.list
  apt-get update || true
  # Puede fallar en kernels nuevos; no bloqueamos el resto del setup
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y gasket-dkms libedgetpu1-std; then
    echo "[WARN] Falló la instalación de Coral. Lo dejamos pendiente para más tarde."
  else
    modprobe gasket || true
    modprobe apex || true
  fi
fi

# ---------- Frigate: ruta y posible disco ----------
mkdir -p "$FRIGATE_DIR"
chown -R toni:toni "$FRIGATE_DIR"
chmod 755 "$FRIGATE_DIR"

if mountpoint -q "$FRIGATE_DIR"; then
  echo "==> ${FRIGATE_DIR} ya está montado. No se toca."
else
  echo "==> ${FRIGATE_DIR} no está montado."
  if [[ -n "$DISK2_DEV" ]]; then
    DEV_PATH="/dev/${DISK2_DEV}"
    PART="${DEV_PATH}1"

    if [[ ! -b "$DEV_PATH" ]]; then
      echo "[WARN] Dispositivo no válido: $DEV_PATH. Omitiendo preparación de disco."
    else
      # Crear partición si no existe
      if [[ ! -b "$PART" ]]; then
        echo "==> Creando partición única en ${DEV_PATH}..."
        umount "${DEV_PATH}"* 2>/dev/null || true
        parted -s "$DEV_PATH" mklabel gpt
        parted -s "$DEV_PATH" mkpart primary ext4 0% 100%
        partprobe "$DEV_PATH"
      fi

      # Detectar fstype actual
      FSTYPE=$(lsblk -no FSTYPE "$PART" || true)
      if [[ "$FSTYPE" != "ext4" ]]; then
        if [[ "$FORCE_FORMAT" == "yes" ]]; then
          echo "==> Formateando $PART a ext4 (forzado)..."
          mkfs.ext4 -F -L FRIGATE "$PART"
        else
          echo "[INFO] $PART no es ext4 (es '$FSTYPE'). No se formatea sin --force-format yes."
        fi
      fi

      # Si ya es ext4 (o se acaba de formatear), montar por fstab
      if [[ "$(lsblk -no FSTYPE "$PART" || true)" == "ext4" ]]; then
        tune2fs -m 0 "$PART" || true
        UUID=$(blkid -s UUID -o value "$PART")
        if ! grep -q "$UUID" /etc/fstab; then
          echo "UUID=$UUID  $FRIGATE_DIR  ext4  defaults,noatime,nodiratime,lazytime  0  2" >> /etc/fstab
        fi
        mount -a
        chown -R toni:toni "$FRIGATE_DIR"
        echo "==> Disco montado en $FRIGATE_DIR"
      else
        echo "[INFO] $PART no está en ext4, montaje omitido."
      fi
    fi
  else
    echo "[INFO] No se indicó --frigate-disk. Se crea solo la ruta ${FRIGATE_DIR}."
  fi
fi

# ---------- SMART y chequeos ----------
systemctl enable --now smartd || true

# ---------- Resumen ----------
echo
echo "==========================================="
echo "  Setup básico v2.3 completado"
echo "==========================================="
echo "Hostname: $(hostname)"
timedatectl | sed -n 's/^[[:space:]]*Time zone: //p'
docker --version || true
docker compose version || true
echo "UFW:"; ufw status verbose || true
echo "Frigate DIR: ${FRIGATE_DIR} (montado: $(mountpoint -q "$FRIGATE_DIR" && echo SI || echo NO))"
echo "Discos:"; df -h | grep -E '/$|'"$FRIGATE_DIR" || true
echo "Coral módulos:"; lsmod | grep -E 'gasket|apex' || echo "Coral no instalada o módulos no cargados (saltado)"
echo
echo "Siguientes pasos:"
echo "1) tailscale up --ssh    # si no iniciaste con authkey"
echo "2) Prueba SSH por Tailscale y desactiva contraseña si no hace falta."
echo "3) Cuando quieras, intentamos Coral de nuevo (drivers para tu kernel)."
echo "Log: $LOG_FILE"
