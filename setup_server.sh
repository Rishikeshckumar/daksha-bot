#!/bin/bash
# Set up the bot server (Ubuntu). Run from the repo folder:   sudo bash setup_server.sh
# Everything lives under $DEPLOYBOT_DIR (venv, config, secrets, SSH key, the bot user's home).
# Override the defaults if you want a different layout:
#   sudo env DEPLOYBOT_DIR=/data/infra/dakshabot BOT_USER=dakshabot GROUP=ops bash setup_server.sh
# Outside $DEPLOYBOT_DIR it only touches: apt packages, the bot user/group entries, and one
# symlink in /etc/systemd/system that points at $DEPLOYBOT_DIR/$SERVICE.service.
set -euo pipefail

B=${DEPLOYBOT_DIR:-/opt/dakshabot}
BOT_USER=${BOT_USER:-dakshabot}
GROUP=${GROUP:-dakshabot}          # members of this group can edit the config under $B
SERVICE=${SERVICE:-dakshabot}
H=$B/home                          # bot user's home (SSH key, ansible tmp, pip cache)
SRC=$(cd "$(dirname "$0")" && pwd)

apt-get update && apt-get install -y python3-venv python3-pip git openssh-client

getent group "$GROUP" >/dev/null || groupadd "$GROUP"
mkdir -p "$B/project/playbooks" "$B/inventory" "$H"
if id "$BOT_USER" &>/dev/null; then
  [ "$(getent passwd "$BOT_USER" | cut -d: -f6)" = "$H" ] || usermod -d "$H" -m "$BOT_USER"
  usermod -aG "$GROUP" "$BOT_USER"
else
  useradd -r -d "$H" -M -s /bin/bash -g "$GROUP" "$BOT_USER"
fi

# Code (always refreshed). Config files are NOT copied: create them as described in README.md.
cp "$SRC/playbooks/deploy_app.yml" "$B/project/playbooks/"
cp "$SRC/bot.py" "$SRC/run_deploy.py" "$SRC/requirements.txt" "$B/"

# Ownership: bot user + group; setgid dirs so new files stay group-writable
chown -R "$BOT_USER:$GROUP" "$B"
find "$B" -path "$H" -prune -o -type d -exec chmod 2775 {} +
find "$B" -path "$H" -prune -o -type f -exec chmod g+rw {} +
chmod 700 "$H"

sudo -u "$BOT_USER" env HOME="$H" python3 -m venv "$B/venv"
sudo -u "$BOT_USER" env HOME="$H" "$B/venv/bin/pip" install -q -r "$B/requirements.txt"

# SSH key used to reach the app servers (the private key never leaves this server)
mkdir -p "$H/.ssh" && chown "$BOT_USER:$GROUP" "$H/.ssh" && chmod 700 "$H/.ssh"
[ -f "$H/.ssh/id_ed25519" ] || sudo -u "$BOT_USER" ssh-keygen -t ed25519 -N "" -C "$BOT_USER@$(hostname)" -f "$H/.ssh/id_ed25519"

# Secrets file: only the bot user can read it
if [ ! -f "$B/$SERVICE.env" ]; then
  printf 'SLACK_BOT_TOKEN=xoxb-REPLACE\nSLACK_APP_TOKEN=xapp-REPLACE\n' > "$B/$SERVICE.env"
fi
chown "$BOT_USER:$GROUP" "$B/$SERVICE.env"; chmod 600 "$B/$SERVICE.env"

# systemd unit kept inside $B and only linked into systemd
cat > "$B/$SERVICE.service" <<EOF
[Unit]
Description=Daksha Bot (Slack Socket Mode + Ansible)
After=network-online.target
Wants=network-online.target

[Service]
User=$BOT_USER
Group=$GROUP
WorkingDirectory=$B
EnvironmentFile=$B/$SERVICE.env
Environment=DEPLOYBOT_DIR=$B
Environment=HOME=$H
Environment=PATH=$B/venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$B/venv/bin/python bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl link "$B/$SERVICE.service"
systemctl daemon-reload

echo
echo "Done. Base dir: $B"
echo " 1. Add this PUBLIC key to ~/.ssh/authorized_keys of the deploy user on every app server:"
cat "$H/.ssh/id_ed25519.pub"
echo " 2. Create the config files from README.md: $B/inventory/hosts.ini, $B/project/projects.yml, $B/users.yml"
echo " 3. Put the Slack tokens in $B/$SERVICE.env"
echo " 4. Test:  sudo -u $BOT_USER env HOME=$H $B/venv/bin/ansible -i $B/inventory/hosts.ini all -m ping"
echo " 5. sudo systemctl enable --now $SERVICE && journalctl -u $SERVICE -f"
