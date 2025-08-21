#!/bin/bash
# AppFlowy Web install + Nginx reverse-proxy at /appflowy on Ubuntu 25.04
# Server IP: 10.70.5.185

set -euo pipefail

SERVER_IP="10.70.5.185"
APP_DIR="/srv/appflowy"
COMPOSE_FILE="$APP_DIR/compose.yml"
NGINX_VHOST="/etc/nginx/conf.d/snipeit.conf"
LOCATION_MARK="# >>> APPFLOWY /appflowy REVERSE PROXY >>>"

# 1) Install Docker & Compose v2
sudo apt update
sudo apt install -y docker.io docker-compose-plugin
sudo systemctl enable --now docker

# 2) Create AppFlowy directory + compose file
sudo mkdir -p "$APP_DIR/data"
sudo chown -R "$USER":"$USER" "$APP_DIR"

cat > "$COMPOSE_FILE" <<'YAML'
services:
  appflowy:
    image: appflowyio/appflowy:latest
    container_name: appflowy
    restart: unless-stopped
    environment:
      - APPFLOWY_MODE=web
      - RUST_BACKTRACE=1
    ports:
      - "8080:8080"
    volumes:
      - ./data:/app/data
YAML

# 3) Start AppFlowy
docker compose -f "$COMPOSE_FILE" up -d

# 4) Add Nginx reverse proxy at /appflowy/
if [ ! -f "$NGINX_VHOST" ]; then
  echo "ERROR: $NGINX_VHOST not found. Make sure your Snipe-IT vhost exists."
  exit 1
fi

# If block already present, skip insert
if grep -q "$LOCATION_MARK" "$NGINX_VHOST"; then
  echo "Nginx reverse-proxy block already present. Skipping edit."
else
  sudo cp "$NGINX_VHOST" "${NGINX_VHOST}.bak.$(date +%s)"
  # Insert our location block just before the closing '}' of the first server block
  sudo awk -v mark="$LOCATION_MARK" '
    BEGIN {inserted=0; depth=0}
    {
      # track braces to find end of first server block
      if ($0 ~ /server[[:space:]]*\{/ && depth==0) { depth=1 }
      if (depth==1 && $0 ~ /^\}/ && inserted==0) {
        print "    " mark
        print "    location /appflowy/ {"
        print "        proxy_pass http://127.0.0.1:8080/;"
        print "        proxy_http_version 1.1;"
        print "        proxy_set_header Upgrade $http_upgrade;"
        print "        proxy_set_header Connection \"upgrade\";"
        print "        proxy_set_header Host $host;"
        print "        proxy_set_header X-Real-IP $remote_addr;"
        print "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
        print "        proxy_set_header X-Forwarded-Proto $scheme;"
        print "    }"
        print "    " mark " END"
        inserted=1
      }
      print
      if (depth>0 && $0 ~ /^\}/) { depth=0 }
    }' "$NGINX_VHOST" | sudo tee "$NGINX_VHOST" >/dev/null
fi

# 5) Test & reload Nginx
sudo nginx -t
sudo systemctl reload nginx

# 6) Quick health check
sleep 2
if curl -fsS "http://127.0.0.1:8080" >/dev/null; then
  echo "AppFlowy container is responding on 8080."
else
  echo "WARNING: AppFlowy did not respond on 8080 yet. Container may still be starting."
fi

echo
echo "✅ AppFlowy installed."
echo "Open: http://$SERVER_IP/appflowy/"
echo
echo "If you later want HTTPS on the whole site, just run certbot for your domain;"
echo "the /appflowy reverse proxy will be covered automatically by your main vhost."
