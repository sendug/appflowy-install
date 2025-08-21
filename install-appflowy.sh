#!/bin/bash
# AppFlowy Cloud install + Nginx reverse-proxy at /appflowy on Ubuntu 25.04
# Server IP used in the final message:
SERVER_IP="10.70.5.185"

set -euo pipefail

APP_DIR="/srv/AppFlowy-Cloud"
NGINX_VHOST="/etc/nginx/conf.d/snipeit.conf"   # adjust if your vhost path differs
HOST_PORT="18080"                               # host port for appflowy nginx (container's 80 -> host 18080)
MARK_BEGIN="# >>> APPFLOWY /appflowy REVERSE PROXY >>>"
MARK_END="# <<< APPFLOWY /appflowy REVERSE PROXY <<<"

# Determine the non-root user who launched the script
RUN_USER="${SUDO_USER:-$USER}"

# Ensure parent dir exists and is owned by the launching user
sudo mkdir -p "$(dirname "$APP_DIR")"
sudo chown -R "$RUN_USER:$RUN_USER" "$(dirname "$APP_DIR")"

as_root() { sudo -H bash -c "$*"; }

echo "==> Installing Docker Engine + Compose v2 from Docker's official repo"
as_root 'apt remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true'
as_root 'apt update && apt install -y ca-certificates curl gnupg lsb-release'
as_root 'install -m 0755 -d /etc/apt/keyrings'
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | as_root 'gpg --dearmor -o /etc/apt/keyrings/docker.gpg'
as_root 'chmod a+r /etc/apt/keyrings/docker.gpg'
UBU_CODENAME="$(lsb_release -cs)"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBU_CODENAME} stable" \
| as_root 'tee /etc/apt/sources.list.d/docker.list >/dev/null'
as_root 'apt update'
as_root 'apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'
as_root 'systemctl enable --now docker'

echo "==> Ensuring current user can access Docker (will try to avoid sudo)"
as_root 'groupadd docker 2>/dev/null || true'
as_root "usermod -aG docker $RUN_USER"
# Try to activate group in this shell; fall back to sudo if it doesn't work in non-interactive shells
if newgrp docker <<<'echo' >/dev/null 2>&1; then
  DOCKER="docker"
else
  DOCKER="sudo docker"
fi

echo "==> Cloning / updating AppFlowy-Cloud"
if [ ! -d "$APP_DIR/.git" ]; then
  sudo -u "$RUN_USER" git clone https://github.com/AppFlowy-IO/AppFlowy-Cloud.git "$APP_DIR"
else
  echo "   Repo already exists, pulling latest..."
  sudo -u "$RUN_USER" git -C "$APP_DIR" pull --ff-only
fi

echo "==> Ensuring .env exists & setting safe defaults for optional vars"
cd "$APP_DIR"
[ -f .env ] || { [ -f .env.example ] && cp .env.example .env || touch .env; }
# Add optional/no-op defaults to silence compose warnings (only append if missing)
for kv in \
  "APPFLOWY_S3_REGION=" \
  "APPFLOWY_S3_PRESIGNED_URL_ENDPOINT=" \
  "AZURE_OPENAI_API_KEY=" \
  "AZURE_OPENAI_ENDPOINT=" \
  "AZURE_OPENAI_API_VERSION=" \
; do
  grep -q "^${kv%%=*}=" .env || echo "$kv" >> .env
done

echo "==> Creating compose override to avoid host port 80 clash (use ${HOST_PORT})"
cat > docker-compose.override.yml <<YAML
services:
  nginx:
    ports:
      - "${HOST_PORT}:80"
YAML

# Optional: try their generator if present (non-interactive first; ignore errors)
if [ -x ./script/generate_env.sh ]; then
  set +e
  ./script/generate_env.sh </dev/null
  set -e
fi

echo "==> Bringing up AppFlowy Cloud stack"
$DOCKER compose up -d

echo "==> Writing reverse proxy block to ${NGINX_VHOST}"
if [ ! -f "$NGINX_VHOST" ]; then
  echo "ERROR: Nginx vhost not found at $NGINX_VHOST."
  echo "       Update NGINX_VHOST in this script to your real vhost path and re-run."
  exit 1
fi

# Backup and replace any prior block
as_root "cp '$NGINX_VHOST' '${NGINX_VHOST}.bak.$(date +%s)'"
as_root "sed -i '/${MARK_BEGIN}/,/${MARK_END}/d' '$NGINX_VHOST'"

# Insert our location block before the first server's closing brace
as_root "awk '
  BEGIN{ins=0; depth=0}
  /server[\\t ]*\\{/ && depth==0 {depth=1}
  {
    if (depth==1 && /^\}/ && ins==0) {
      print \"    ${MARK_BEGIN}\"
      print \"    location /appflowy/ {\"\n\
            \"        proxy_pass http://127.0.0.1:${HOST_PORT}/;\"\n\
            \"        proxy_http_version 1.1;\"\n\
            \"        proxy_set_header Upgrade \\$http_upgrade;\"\n\
            \"        proxy_set_header Connection \\\"upgrade\\\";\"\n\
            \"        proxy_set_header Host \\$host;\"\n\
            \"        proxy_set_header X-Real-IP \\$remote_addr;\"\n\
            \"        proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for;\"\n\
            \"        proxy_set_header X-Forwarded-Proto \\$scheme;\"\n\
            \"    }\"\n\
            \"    ${MARK_END}\"
      ins=1
    }
    print
    if (depth>0 && /^\}/) depth=0
  }' '$NGINX_VHOST' > '${NGINX_VHOST}.tmp' && mv '${NGINX_VHOST}.tmp' '$NGINX_VHOST'"

echo "==> Testing & reloading Nginx"
as_root 'nginx -t'
as_root 'systemctl reload nginx'

echo "==> Health check"
sleep 2
if curl -fsS "http://127.0.0.1:${HOST_PORT}/" >/dev/null 2>&1; then
  echo "   AppFlowy nginx is responding on ${HOST_PORT}."
else
  echo "   WARNING: AppFlowy may still be starting. Check: cd $APP_DIR && $DOCKER compose logs -f"
fi

echo
echo "✅ AppFlowy Cloud installed and proxied."
echo "Open: http://${SERVER_IP}/appflowy/"
echo
echo "Tips:"
echo "- See containers:   cd $APP_DIR && $DOCKER compose ps"
echo "- View logs:        cd $APP_DIR && $DOCKER compose logs -f"
echo "- Update AppFlowy:  cd $APP_DIR && sudo -u \"$RUN_USER\" git pull && $DOCKER compose pull && $DOCKER compose up -d"
