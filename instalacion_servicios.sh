#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
#  GRANXA STACK - INSTALACIÓN COMPLETA
#  Frigate + Coral PCIe + go2rtc + Mosquitto (contenedor)
#  Node-RED + CompreFace + Home Assistant + Jobs
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

echo "======================================"
echo "VARIABLES REQUERIDAS EN EL .env:"
echo
echo "  TZ, PUID, PGID"
echo "  MQTT_USER, MQTT_PASS"
echo "  FRIGATE_MEDIA"
echo "======================================"
read -r -p "¿Continuar? (s/n): " CONT
[[ "$CONT" =~ ^[Ss]$ ]] || exit 1

# -------- Cargar .env --------
if [[ -f "$ENV_FILE" ]]; then
  read -r -p "¿Cargar .env? (s/n): " USEENV
  if [[ "$USEENV" =~ ^[Ss]$ ]]; then
    set -a; source "$ENV_FILE"; set +a
  fi
fi

TZ="${TZ:-Europe/Madrid}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
MQTT_USER="${MQTT_USER:-granxa}"
MQTT_PASS="${MQTT_PASS:-CHANGEME}"
FRIGATE_MEDIA="${FRIGATE_MEDIA:-/srv/media/frigate}"
PLATE_RECOGNIZER_TOKEN="${PLATE_RECOGNIZER_TOKEN:-}"
CAMERA_USER="${CAMERA_USER:-admin}"
CAMERA_PASS="${CAMERA_PASS:-changeme}"

echo "======================================"
echo "USANDO ESTAS VARIABLES:"
echo "TZ=$TZ"
echo "MQTT_USER=$MQTT_USER"
echo "FRIGATE_MEDIA=$FRIGATE_MEDIA"
echo "======================================"
read -r -p "¿Correcto? (s/n): " OK
[[ "$OK" =~ ^[Ss]$ ]] || exit 1

# -------- Comprobaciones --------
command -v docker >/dev/null || { echo "❌ Falta Docker"; exit 1; }
command -v docker compose >/dev/null || { echo "❌ Falta docker compose"; exit 1; }

# -------- Estructura de carpetas --------
BASE="/opt/granxa"
COMPOSE_DIR="$BASE/compose"
DATA_DIR="$BASE/data"

mkdir -p \
  "$COMPOSE_DIR"/{frigate/config,go2rtc,mosquitto/config,nodered,compreface,redis,homeassistant,jobs,alpr} \
  "$DATA_DIR"/{mosquitto,nodered,compreface/postgres,redis,homeassistant,jobs,alpr} \
  "$FRIGATE_MEDIA"

chown -R "$PUID:$PGID" "$BASE" "$FRIGATE_MEDIA" || true

# -------- .env del compose --------
cat > "$COMPOSE_DIR/.env" <<EOF
TZ=$TZ
PUID=$PUID
PGID=$PGID
MQTT_USER=$MQTT_USER
MQTT_PASS=$MQTT_PASS
FRIGATE_MEDIA=$FRIGATE_MEDIA
PLATE_RECOGNIZER_TOKEN=$PLATE_RECOGNIZER_TOKEN
CAMERA_USER=$CAMERA_USER
CAMERA_PASS=$CAMERA_PASS
EOF

# -------- Mosquitto (passwd generado en el host sin instalar mosquitto) --------
PASSFILE="$COMPOSE_DIR/mosquitto/config/passwd"
mkdir -p "$(dirname "$PASSFILE")"
echo -e "${MQTT_USER}:${MQTT_PASS}" > "$PASSFILE"
chmod 600 "$PASSFILE"

MOSQ_CONF="$COMPOSE_DIR/mosquitto/config/mosquitto.conf"
cat > "$MOSQ_CONF" <<'EOF'
persistence true
persistence_location /mosquitto/data/
listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd
EOF

# -------- Frigate config --------
FRIGATE_CFG="$COMPOSE_DIR/frigate/config/config.yml"
cat > "$FRIGATE_CFG" <<EOF
mqtt:
  host: mosquitto
  user: ${MQTT_USER}
  password: ${MQTT_PASS}

detectors:
  coral:
    type: edgetpu
    device: pci

go2rtc:
  streams:
    robot_frontal_main: rtsp://${CAMERA_USER}:${CAMERA_PASS}@192.168.80.100:554/Streaming/Channels/101
    robot_frontal_sub:  rtsp://${CAMERA_USER}:${CAMERA_PASS}@192.168.80.100:554/Streaming/Channels/102

    robot_zonatecnica_main: rtsp://${CAMERA_USER}:${CAMERA_PASS}@192.168.80.101:554/Streaming/Channels/101
    robot_zonatecnica_sub:  rtsp://${CAMERA_USER}:${CAMERA_PASS}@192.168.80.101:554/Streaming/Channels/102

    exterior_main: rtsp://${CAMERA_USER}:${CAMERA_PASS}@192.168.80.103:554/Streaming/Channels/101
    exterior_sub:  rtsp://${CAMERA_USER}:${CAMERA_PASS}@192.168.80.103:554/Streaming/Channels/102

cameras:
  camera_exterior:
    ffmpeg:
      inputs:
        - path: rtsp://go2rtc:8554/exterior_sub
          roles: [detect]
        - path: rtsp://go2rtc:8554/exterior_main
          roles: [record]
    detect:
      width: 1920
      height: 1080
      fps: 5
EOF

# -------- Node Jobs --------
cat > "$COMPOSE_DIR/jobs/Dockerfile" <<'EOF'
FROM node:20-alpine
RUN apk add --no-cache bash curl
WORKDIR /app
CMD ["node", "/app/hourly-task.js"]
EOF

cat > "$DATA_DIR/jobs/hourly-task.js" <<'EOF'
console.log(new Date().toISOString(), "Tarea horaria ejecutada");
EOF

# -------- docker-compose.yml --------
cat > "$COMPOSE_DIR/docker-compose.yml" <<'EOF'
services:
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    ports:
      - "1883:1883"
    volumes:
      - ./mosquitto/config:/mosquitto/config
      - ../data/mosquitto:/mosquitto/data
    restart: unless-stopped

  go2rtc:
    image: alexxit/go2rtc:latest
    container_name: go2rtc
    ports:
      - "1984:1984"
      - "8554:8554"
    volumes:
      - ./go2rtc:/config
    restart: unless-stopped

  frigate:
    image: ghcr.io/blakeblackshear/frigate:stable
    container_name: frigate
    privileged: true
    shm_size: "512m"
    devices:
      - /dev/apex_0:/dev/apex_0
      - /dev/dri:/dev/dri
    ports:
      - "5000:5000"
    volumes:
      - ./frigate/config:/config
      - ${FRIGATE_MEDIA}:/media/frigate
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    container_name: redis
    volumes:
      - ../data/redis:/data
    restart: unless-stopped

  nodered:
    image: nodered/node-red:3.1
    container_name: nodered
    ports:
      - "1880:1880"
    volumes:
      - ../data/nodered:/data
    restart: unless-stopped

  compreface-postgres:
    image: postgres:14-alpine
    container_name: compreface-postgres
    environment:
      POSTGRES_DB: compreface
      POSTGRES_USER: compreface
      POSTGRES_PASSWORD: compreface
    volumes:
      - ../data/compreface/postgres:/var/lib/postgresql/data
    restart: unless-stopped

  compreface-api:
    image: exadel/compreface-api:1.2.0
    container_name: compreface-api
    environment:
      POSTGRES_URL: jdbc:postgresql://compreface-postgres:5432/compreface
      POSTGRES_USER: compreface
      POSTGRES_PASSWORD: compreface
    ports:
      - "8080:8080"
    restart: unless-stopped
    depends_on:
      - compreface-postgres

  compreface-core:
    image: exadel/compreface-core:1.2.0
    container_name: compreface-core
    restart: unless-stopped
    depends_on:
      - compreface-api

   compreface-fe:
    image: exadel/compreface-fe:1.2.0
    container_name: compreface-fe
    ports:
      - "8000:80"        # el contenedor escucha en 80, lo exponemos como 8000 fuera
    restart: unless-stopped
    depends_on:
      - compreface-core
      - compreface-api

  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    ports:
      - "8123:8123"
    volumes:
      - ../data/homeassistant:/config
    restart: unless-stopped

  node-jobs:
    build:
      context: ./jobs
    container_name: node-jobs
    volumes:
      - ../data/jobs:/app
    restart: unless-stopped
EOF

cd "$COMPOSE_DIR"
docker compose pull
docker compose up -d

echo "======================================"
echo "✅ INSTALACIÓN COMPLETA"
echo "Frigate → http://IP:5000"
echo "go2rtc → http://IP:1984"
echo "Node-RED → http://IP:1880"
echo "CompreFace → http://IP:8000"
echo "Home Assistant → http://IP:8123"
echo "======================================"
