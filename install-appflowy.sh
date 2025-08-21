#!/bin/bash
# AppFlowy Cloud install + Nginx reverse-proxy at /appflowy on Ubuntu 25.04
# Server IP for final message:
SERVER_IP="10.70.5.185"

set -euo pipefail

APP_DIR="/srv/AppFlowy-Cloud"
NGINX_VHOST="/etc/nginx/conf.d/snipeit.conf"
MARK_BEGIN="# >>> APPFLOWY /appflowy REVERSE PROXY >>>"
MARK_END="# <<< APPFLOWY /appflowy REVERSE PROXY <<<"

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

# Allow current user to run docker without sudo (will take effect in this shell via newgrp)
as_root 'groupadd docker 2>/dev/null || true'
as_root "usermod -aG docker $USER"
if newgrp docker <<<'echo' >/dev/null 2>&1; then
  DOCKER="docker"
else
  DOCKER="sudo docker"
fi

echo "==> Cloning AppFlowy-Cloud"
as_root "mkdir -p $(dirname "$APP_DIR")"
as_root "chown $USER:$USER $(dirname "$APP_DIR")"
if [ ! -d "$APP_DIR/.git" ]; then
  git clone https://github.com/AppFlowy-IO/AppFlowy-Cloud.git "$APP_DIR"
else
  echo "   Repo already exists, pulling latest..."
  (cd "$APP_DIR" && git pull --ff-only)
fi

echo "==> Generating AppFlowy .env (interactive if script requires it)"
# Try non-interactive first; fall back to interactive if needed
set +e
( cd "$APP_DIR" && ./script/generate_env.sh </dev/null )
GEN_RC=$?
set -e
if [ $GEN_RC -ne 0 ]; then
  echo "   The generator may be interactive in this version; launching interactively..."
  ( cd "$APP_DIR" && ./script/generate_env.sh )
fi

echo "==> Bringing up AppFlowy Cloud stack (first run can take several minutes)"
# AppFlowy helper handles compose; --reset ensures fresh start
( cd "$APP_DIR" && ./script/run_local_server.sh --reset )

echo "==> Detecting exposed web port t
