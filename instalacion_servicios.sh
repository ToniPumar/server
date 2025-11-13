#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# deploy_granxa_stack.sh
# - Muestra variables requeridas (.env), ofrece cargarlo y pide confirmación
# - Despliega: Frigate (Coral PCIe), go2rtc, Mosquitto (con auth),
#   Node-RED, Redis, CompreFace(+Postgres), Home Assistant,
#   y Node Jobs (cron cada hora). Plate Recognizer por perfil opcional.
# - Persistencia en /opt/granxa/data y /srv/media/frigate
# - Cámaras:
#     192.168.80.100 -> cam robot frontal
#     192.168.80.101 -> cam zona técnica robot
#     192.168.80.103 -> cam exterior
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

echo "======================================"
echo "VARIABLES REQUERIDAS EN EL .env (si lo usas):"
echo
echo "  TZ                      Zona horaria. Ej: Europe/Madrid"
echo "  PUID, PGID              UID/GID de archivos. Ej: 1000, 1000"
echo "  MQTT_USER, MQTT_PASS    Usuario/clave MQTT   Ej: toni, churrasco"
echo "  FRIGATE_MEDIA           Ruta datos Frigate   Ej: /srv/media/frigate"
echo "  PLATE_RECOGNIZER_TOKEN  Token ALPR (opcional, vacío si no)"
echo "  CAMERA_USER, CAMERA_PASS Credenciales cámaras RTSP (globales)"
echo "======================================"
read -r -p "¿Continuar? (s/n): " CONT1
[[ "$CONT1" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 1; }

TZ="${TZ:-Europe/Madrid}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
MQTT_USER="${MQTT_USER:-granxa}"
MQTT_PASS="${MQTT_PASS:-Cambia_Esta_Clave_Larga_2025}"
FRIGATE_MEDIA="${FRIGATE_MEDIA:-/srv/media/frigate}"
PLATE_RECOGNIZER_TOKEN="${PLATE_RECOGNIZER_TOKEN:-}"
CAMERA_USER="${CAMERA_USER:-admin}"
CAMERA_PASS="${CAMERA_PASS:-changeme}"

if [[ -f "$ENV_FILE" ]]; then
  echo "🔎 Encontrado .env en: $ENV_FILE"
  read -r -p "¿Cargar este .env? (s/n): " LOADENV
  if [[ "$LOADENV" =~ ^[Ss]$ ]]; then
    echo "📦 Cargando variables del .env..."
    set -a
    source "$ENV_FILE"
    set +a
  else
    echo "⚠️  No se cargó el .env. Se usarán valores por defecto o de entorno."
  fi
else
  echo "⚠️  No hay .env junto al script. Se usarán valores por defecto o de entorno."
fi

echo "======================================"
echo "VALORES FINALES QUE SE USARÁN:"
echo "  TZ=$TZ"
echo "  PUID=$PUID"
echo "  PGID=$PGID"
echo "  MQTT_USER=$MQTT_USER"
echo "  MQTT_PASS=$MQTT_PASS"
echo "  FRIGATE_MEDIA=$FRIGATE_MEDIA"
echo "  PLATE_RECOGNIZER_TOKEN=$PLATE_RECOGNIZER_TOKEN"
echo "  CAMERA_USER=$CAMERA_USER"
echo "  CAMERA_PASS=$CAMERA_PASS"
echo "======================================"
read -r -p "¿Deseas continuar con estas variables? (s/n): " CONT2
[[ "$CONT2" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 1; }

command -v docker >/dev/null || { echo "❌ Docker no está instalado"; exit 1; }
command -v docker compose >/dev/null || { echo "❌ Falta docker compose"; exit 1; }

BASE="/opt/granxa"
COMPOSE_DIR="${BASE}/compose"
DATA_DIR="${BASE}/data"

echo "➡️  Creando estructura de carpetas..."
mkdir -p \
  "${COMPOSE_DIR}/"{frigate/config,go2rtc,mosquitto/config,nodered,compreface,redis,homeassistant,jobs,alpr} \
  "${DATA_DIR}/"{mosquitto,nodered,compreface/postgres,redis,homeassistant,jobs,alpr} \
  "${FRIGATE_MEDIA}"

echo "➡️  Ajustando permisos a ${PUID}:${PGID}..."
chown -R "${PUID}:${PGID}" "${BASE}" "${FRIGATE_MEDIA}" || true

COMPOSE_ENV="${COMPOSE_DIR}/.env"
echo "➡️  Generando ${COMPOSE_ENV}..."
cat > "${COMPOSE_ENV}" <<EOF
TZ=${TZ}
FRIGATE_MEDIA=${FRIGATE_MEDIA}
MQTT_USER=${MQTT_USER}
MQTT_PASS=${MQTT_PASS}
PLATE_RECOGNIZER_TOKEN=${PLATE_RECOGNIZER_TOKEN}
PUID=${PUID}
PGID=${PGID}
CAMERA_USER=${CAMERA_USER}
CAMERA_PASS=${CAMERA_PASS}
EOF

# -------- 7) Mosquitto (conf + passwd) --------
MOSQ_DIR="${COMPOSE_DIR}/mosquitto"
mkdir -p "${MOSQ_DIR}/config" "${MOSQ_DIR}/data"

MOSQ_CONF="${MOSQ_DIR}/config/mosquitto.conf"
echo "➡️  Escribiendo ${MOSQ_CONF}..."
cat > "${MOSQ_CONF}" <<'EOF'
persistence true
persistence_location /mosquitto/data/
log_timestamp true
log_type error
log_type warning
log_type notice

listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd
EOF

echo "➡️  Creando fichero de contraseñas de Mosquitto..."
# Asegurarse de que mosquitto_passwd está disponible en el host
if ! command -v mosquitto_passwd >/dev/null 2>&1; then
  echo "   mosquitto_passwd no encontrado; instalando mosquitto-clients..."
  apt-get update && apt-get install -y mosquitto-clients
fi

PASSFILE="${MOSQ_DIR}/config/passwd"
touch "${PASSFILE}"
mosquitto_passwd -b "${PASSFILE}" "${MQTT_USER}" "${MQTT_PASS}"
chmod 600 "${PASSFILE}"

# -------- 8) Frigate config con cámaras --------
FRIGATE_CFG="${COMPOSE_DIR}/frigate/config/config.yml"
echo "➡️  Escribiendo config de Frigate en ${FRIGATE_CFG}..."
cat > "${FRIGATE_CFG}" <<'EOF'
mqtt:
  host: mosquitto
  user: ${MQTT_USER}
  password: ${MQTT_PASS}
  topic_prefix: frigate

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
  camera_robot_frontal:
    ffmpeg:
      inputs:
        - path: rtsp://go2rtc:8554/robot_frontal_sub
          roles: [detect]
        - path: rtsp://go2rtc:8554/robot_frontal_main
          roles: [record]
    detect:
      width: 1920
      height: 1080
      fps: 5
    live:
      enabled: true

  camera_robot_zonatecnica:
    ffmpeg:
      inputs:
        - path: rtsp://go2rtc:8554/robot_zonatecnica_sub
          roles: [detect]
        - path: rtsp://go2rtc:8554/robot_zonatecnica_main
          roles: [record]
    detect:
      width: 1280
      height: 720
      fps: 5
    live:
      enabled: true

  camera_exterior:
    ffmpeg:
      inputs:
        - path: rtsp://go2rtc:8554/exterior_sub
          roles: [detect]
        - path: rtsp://go2rtc:8554/exterior_main
          roles: [record]
    detect:
      width: 1280
      height: 720
      fps: 5
    live:
      enabled: true

record:
  enabled: true

snapshots:
  enabled: true
  retain:
    default: 3
EOF

# -------- 9) Node Jobs (cron) --------
echo "➡️  Preparando contenedor Node Jobs (cron cada hora)..."
cat > "${COMPOSE_DIR}/jobs/Dockerfile" <<'EOF'
FROM node:20-alpine
RUN apk add --no-cache curl ca-certificates bash \
 && curl -fsSL -o /usr/local/bin/supercronic https://github.com/aptible/supercronic/releases/download/v0.2.4/supercronic-linux-amd64 \
 && chmod +x /usr/local/bin/supercronic
WORKDIR /app
CMD ["supercronic", "/app/crontab"]
EOF

cat > "${COMPOSE_DIR}/jobs/crontab" <<'EOF'
5 * * * * node /app/hourly-task.js >> /app/jobs.log 2>&1
0 3 * * * truncate -s 0 /app/jobs.log
EOF

JOB_SCRIPT="${DATA_DIR}/jobs/hourly-task.js"
if [[ ! -f "${JOB_SCRIPT}" ]]; then
  echo "➡️  Creando script ejemplo de tarea horaria en ${JOB_SCRIPT}..."
  cat > "${JOB_SCRIPT}" <<'EOF'
// /opt/granxa/data/jobs/hourly-task.js
console.log(new Date().toISOString(), "Job horario OK");
// Aquí puedes poner tu lógica: limpieza, backup, sincronización, etc.
EOF
  chown -R "${PUID}:${PGID}" "${DATA_DIR}/jobs" || true
fi

# -------- 10) docker-compose.yml --------
DC_FILE="${COMPOSE_DIR}/docker-compose.yml"
echo "➡️  Generando ${DC_FILE}..."
cat > "${DC_FILE}" <<'EOF'
version: "3.9"

x-health: &default-health
  interval: 10s
  timeout: 3s
  retries: 10
  start_period: 20s

networks:
  granxa:
    driver: bridge

services:
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    networks: [granxa]
    volumes:
      - ./mosquitto/config/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - ./mosquitto/config/passwd:/mosquitto/config/passwd:ro
      - ../data/mosquitto:/mosquitto/data
    ports:
      - "1883:1883"
    healthcheck:
      test: ["CMD", "mosquitto_pub", "-h", "localhost", "-t", "health", "-m", "ok"]
      <<: *default-health
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    container_name: redis
    networks: [granxa]
    command: ["redis-server", "--appendonly", "yes", "--appendfsync", "everysec"]
    volumes:
      - ../data/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      <<: *default-health
    restart: unless-stopped

  go2rtc:
    image: alexxit/go2rtc:latest
    container_name: go2rtc
    networks: [granxa]
    environment:
      - TZ=${TZ}
    volumes:
      - ./frigate/config:/config
    ports:
      - "1984:1984"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:1984/api/version"]
      <<: *default-health
    restart: unless-stopped

  frigate:
    image: ghcr.io/blakeblackshear/frigate:stable
    container_name: frigate
    networks: [granxa]
    depends_on:
      mosquitto:
        condition: service_healthy
      go2rtc:
        condition: service_healthy
    privileged: true
    shm_size: "512m"
    tmpfs:
      - /tmp:size=256m
    devices:
      - /dev/apex_0:/dev/apex_0
      - /dev/dri:/dev/dri
    volumes:
      - ./frigate/config:/config
      - ${FRIGATE_MEDIA}:/media/frigate
      - /etc/localtime:/etc/localtime:ro
    environment:
      - TZ=${TZ}
    ports:
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:5000"]
      <<: *default-health
    restart: unless-stopped

  nodered:
    image: nodered/node-red:3.1
    container_name: nodered
    user: "${PUID}:${PGID}"
    networks: [granxa]
    environment:
      - TZ=${TZ}
    ports:
      - "1880:1880"
    volumes:
      - ../data/nodered:/data
    depends_on:
      mosquitto:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:1880"]
      <<: *default-health
    restart: unless-stopped

  compreface-postgres:
    image: postgres:14-alpine
    container_name: compreface-postgres
    networks: [granxa]
    environment:
      POSTGRES_DB: compreface
      POSTGRES_USER: compreface
      POSTGRES_PASSWORD: compreface
    volumes:
      - ../data/compreface/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U compreface"]
      <<: *default-health
    restart: unless-stopped

  compreface-api:
    image: exadel/compreface-api:1.2.0
    container_name: compreface-api
    networks: [granxa]
    environment:
      POSTGRES_URL: jdbc:postgresql://compreface-postgres:5432/compreface
      POSTGRES_USER: compreface
      POSTGRES_PASSWORD: compreface
      SPRING_PROFILES_ACTIVE: dev
    depends_on:
      compreface-postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/api/health"]
      <<: *default-health
    restart: unless-stopped

  compreface-core:
    image: exadel/compreface-core:1.2.0
    container_name: compreface-core
    networks: [granxa]
    environment:
      ML_PORT: 3000
    depends_on:
      compreface-api:
        condition: service_started
    restart: unless-stopped

  compreface-fe:
    image: exadel/compreface-fe:1.2.0
    container_name: compreface-fe
    networks: [granxa]
    ports:
      - "8000:80"
    depends_on:
      compreface-api:
        condition: service_started
      compreface-core:
        condition: service_started
    restart: unless-stopped

  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    network_mode: host
    environment:
      - TZ=${TZ}
    user: "${PUID}:${PGID}"
    volumes:
      - ../data/homeassistant:/config
      - /etc/localtime:/etc/localtime:ro
    depends_on:
      frigate:
        condition: service_started
      mosquitto:
        condition: service_healthy
    restart: unless-stopped

  node-jobs:
    build:
      context: ./jobs
    container_name: node-jobs
    networks: [granxa]
    environment:
      - TZ=${TZ}
    user: "${PUID}:${PGID}"
    volumes:
      - ../data/jobs:/app
    healthcheck:
      test: ["CMD", "sh", "-c", "test -e /app/crontab"]
      <<: *default-health
    restart: unless-stopped

  # ALPR opcional. Actívalo con: docker compose --profile alpr up -d
  alpr:
    profiles: ["alpr"]
    image: platerecognizer/alpr:latest
    container_name: plate-recognizer
    networks: [granxa]
    environment:
      - TZ=${TZ}
      - TOKEN=${PLATE_RECOGNIZER_TOKEN}
    volumes:
      - ../data/alpr:/var/lib/plate-recognizer
    ports:
      - "8080:8080"
    restart: unless-stopped
EOF

# -------- 11) Helper de arranque futuro --------
LAUNCH="${COMPOSE_DIR}/setup_apps_granxa.sh"
echo "➡️  Creando helper ${LAUNCH}..."
cat > "${LAUNCH}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
echo "docker compose pull..."
docker compose pull
echo "docker compose up -d..."
docker compose up -d
echo "Hecho. Paneles:
- Frigate:        http://<IP>:5000
- go2rtc:         http://<IP>:1984
- Node-RED:       http://<IP>:1880
- CompreFace GUI: http://<IP>:8000
- Home Assistant: http://<IP>:8123 (modo host)
ALPR opcional:
- Edita .env y pon PLATE_RECOGNIZER_TOKEN
- docker compose --profile alpr up -d"
EOF
chmod +x "${LAUNCH}"

# -------- 12) Pull y arranque --------
echo "➡️  Descargando imágenes y arrancando servicios..."
cd "${COMPOSE_DIR}"
docker compose pull
docker compose up -d

echo
echo "✅ Despliegue completo."
echo "Abre:"
echo "- Frigate:        http://<IP_DEL_SERVIDOR>:5000"
echo "- go2rtc:         http://<IP_DEL_SERVIDOR>:1984"
echo "- Node-RED:       http://<IP_DEL_SERVIDOR>:1880"
echo "- CompreFace GUI: http://<IP_DEL_SERVIDOR>:8000"
echo "- Home Assistant: http://<IP_DEL_SERVIDOR>:8123"
echo
echo "Persistencia:"
echo "- Frigate media:  ${FRIGATE_MEDIA}"
echo "- Config/datos:   ${DATA_DIR}"
echo
echo "ALPR opcional:"
echo "- Edita ${COMPOSE_DIR}/.env y pon PLATE_RECOGNIZER_TOKEN, luego:"
echo "  docker compose --profile alpr up -d"
echo
echo "Node Jobs:"
echo "- Edita: ${DATA_DIR}/jobs/hourly-task.js"
echo "- Logs:  ${DATA_DIR}/jobs/jobs.log"
