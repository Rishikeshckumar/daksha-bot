# Daksha Bot: intelligent deploy automation

A Slack bot that runs predefined, Ansible-driven deployments on servers in a **private subnet**, with no
inbound ports: Slack Socket Mode opens an outbound websocket. This repo is a **generic template**: bring your
own per-project `deploy.sh` (contract below).

```
/deploy myapp [branch]
  -> Slack (Socket Mode, outbound websocket)
  -> bot.py          checks project, branch name, user permission, per-project lock
  -> run_deploy.py   starts Ansible (playbooks/deploy_app.yml)
  -> Ansible         SSH to the app server, runs: bash deploy.sh <branch>   (in the project's folder)
  -> deploy.sh       your script: build, restart, health check, rollback on failure
  -> bot posts the steps, a result, and on failure the error report as a file
```

## Repo layout
```
bot.py                      Slack handler: /deploy list | /deploy <project> [branch]
run_deploy.py               runs the playbook with ansible-runner, parses deploy.sh output
playbooks/deploy_app.yml    runs the project's deploy.sh on the target host
setup_server.sh             one-time setup of the bot server (user, venv, SSH key, systemd unit)
config-examples/            placeholder versions of every config file (copy, then edit)
requirements.txt
```
Live config (hosts, projects, users, tokens) is **not** in the repo; the `.gitignore` keeps it out.

## Requirements
- Bot server: Ubuntu 22.04+, outbound HTTPS (443) to Slack, SSH (22) to the app servers.
- App servers: SSH, `bash`, `git`, Python 3 (Ansible needs it), plus whatever your `deploy.sh` uses.
- A Slack workspace where you can create an app (the Free plan works).

## 1. Create the Slack app
1. https://api.slack.com/apps -> **Create New App -> From scratch**.
2. **Socket Mode**: enable it; create an app-level token with scope `connections:write` (`xapp-...`).
3. **Slash Commands -> Create New Command**: `/deploy`, any placeholder Request URL, usage hint `<project> [branch] | list`.
4. **OAuth & Permissions -> Bot Token Scopes**: `commands`, `chat:write`, `chat:write.public`, `files:write`.
5. **Install to Workspace** (reinstall after any scope or command change). Copy the Bot token (`xoxb-...`).
6. Each person's Slack member ID: profile -> ⋮ -> *Copy member ID*.

## 2. Set up the bot server
```bash
git clone https://github.com/<you>/daksha-bot.git && cd daksha-bot
sudo bash setup_server.sh
# custom layout (e.g. keep everything under /data/infra):
# sudo env DEPLOYBOT_DIR=/data/infra/dakshabot BOT_USER=dakshabot GROUP=ops bash setup_server.sh
```
It creates the bot user, a venv, an SSH key and a systemd unit, then prints the **public** key.
Only ever copy the `.pub` file. Never paste the private key anywhere.

## 3. Create the deploy user on each app server
```bash
sudo useradd -m -s /bin/bash deploy
sudo mkdir -p /home/deploy/.ssh
echo "PASTE_THE_PUBLIC_KEY_LINE" | sudo tee -a /home/deploy/.ssh/authorized_keys
sudo chown -R deploy: /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh && sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chmod go-w /home/deploy                         # sshd rejects a group-writable home
sudo chown -R deploy: /opt/apps/myapp                # the project folder
sudo -u deploy git ls-remote https://git.example.com/org/myapp.git | head -3   # must not prompt
```
Git must work without a prompt for this user (credential helper with a read-only token, or an SSH deploy key).
The app must run as this user, not root, or your stop step cannot stop it. If it runs as root today, stop it once
as root, `chown -R deploy:` the folder, and start it again as `deploy`.

## 4. Provide a deploy script per project (the contract)
Put a `deploy.sh` in each project's `base_dir` on the app server. The playbook runs it as
`bash deploy.sh [branch]` from that folder, and `run_deploy.py` reads its output:

| Contract | Detail |
|---|---|
| Exit code | `0` deployed, `1` failed and the previous version is running again, `2` failed and the rollback failed |
| Progress lines | print `STEP: <name>` before each stage, `OK: ...` at the end; on failure `FAILED: ...`, and `ROLLBACK: ...` for rollback actions |
| Failure report | print the diagnostic text between a line `REPORT-BEGIN` and a line `REPORT-END` (the bot uploads it to Slack) |
| Non-interactive | no prompts (no `sudo` password, no git credential prompt) |
| Locking | refuse to run twice at once in the same folder (for example `flock -n`) |

Typical stages: stop, back up the current build, fetch the branch, build, start, check the process stays up,
and restore the backup if any stage fails.

## 5. Create the config files
Copy the placeholders in [config-examples/](config-examples/) and edit them, or create them with the blocks
below. Placeholders only: replace the values. `B` is the bot's base directory.

```bash
B=/opt/dakshabot

# Slack tokens (chmod 600, owner = bot user; setup_server.sh already created this file)
sudo tee $B/dakshabot.env >/dev/null <<'EOF'
SLACK_BOT_TOKEN=xoxb-your-bot-token
SLACK_APP_TOKEN=xapp-your-app-token
EOF
sudo chmod 600 $B/dakshabot.env

# Ansible inventory: one line per app server
sudo tee $B/inventory/hosts.ini >/dev/null <<'EOF'
[app_servers]
app-server-1 ansible_host=192.0.2.10 ansible_user=deploy

[all:vars]
ansible_ssh_private_key_file=/opt/dakshabot/home/.ssh/id_ed25519
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30'
ansible_python_interpreter=/usr/bin/python3
EOF

# Project registry: one block per project. `host` must match a name in hosts.ini
sudo tee $B/project/projects.yml >/dev/null <<'EOF'
projects:
  myapp:
    host: app-server-1
    type: app
    base_dir: /opt/apps/myapp        # folder that holds deploy.sh
    default_branch: main             # shown in /deploy list
    allowed: [admins, developers]    # groups from users.yml
EOF

# Who may deploy: groups -> Slack member IDs
sudo tee $B/users.yml >/dev/null <<'EOF'
groups:
  admins:
    - U0000000000
  developers:
    - U1111111111
EOF

sudo chown -R dakshabot:dakshabot $B/inventory $B/project $B/users.yml
```

## 6. Test, in this order
```bash
B=/opt/dakshabot

# a) SSH + Ansible reach the host (expect "pong")
sudo -u dakshabot env HOME=$B/home $B/venv/bin/ansible -i $B/inventory/hosts.ini app-server-1 -m ping

# b) on the app server: run your deploy script by hand, then a failure case (expect rollback + a report)
cd /opt/apps/myapp && sudo -u deploy bash deploy.sh

# c) through Ansible, without Slack
sudo -u dakshabot env HOME=$B/home $B/venv/bin/ansible-playbook -i $B/inventory/hosts.ini \
  $B/project/playbooks/deploy_app.yml -e project=myapp -e target=app-server-1 -e branch=main

# d) start the bot and use it from Slack
sudo systemctl enable --now dakshabot
journalctl -u dakshabot -f          # look for "Bolt app is running!"
```

## 7. Usage
| Slack command | What it does |
|---|---|
| `/deploy` or `/deploy list` | list projects |
| `/deploy myapp` | deploy the project's default branch |
| `/deploy myapp feature-x` | deploy a branch |

```bash
sudo systemctl status|restart dakshabot      # restart after changing bot.py, run_deploy.py or the env file
journalctl -u dakshabot -n 50 --no-pager
```
`projects.yml` and `users.yml` are re-read on every command, so no restart is needed for those.

## How it works
- **Authorization:** `allowed` groups in `projects.yml`, mapped to Slack member IDs in `users.yml`.
- **Locks:** an in-memory lock per project in the bot; your `deploy.sh` should hold its own lock on the server.
- **Input safety:** branch names are validated, and the bot runs only the named playbook, never free-form commands.
- **Result:** the playbook's exit code (`0`, `1`, `2`) decides the Slack result; the failure report between
  `REPORT-BEGIN` and `REPORT-END` is uploaded as a file (needs the `files:write` scope).

## Troubleshooting
| Symptom | Cause / fix |
|---|---|
| Slackbot: "`/deploy` is not a valid command" | the slash command was never created in the Slack app (step 1.3); reinstall the app |
| `/deploy` shows nothing and the log is empty | Socket Mode is off, or the app was not reinstalled after changes |
| `Permission denied (publickey)` in Ansible | public key missing in the deploy user's `authorized_keys`, or wrong permissions (step 3) |
| `Connection timed out` | port 22 blocked by a security group or firewall |
| `Operation not permitted` when stopping the app | the app runs as another user (for example root): stop it once, `chown -R`, restart as the deploy user |
| A password prompt during a deploy | `sudo` inside a script, or git asking for credentials: make both non-interactive |
| `another deploy is already running` | the lock works; wait, or check `ps -ef \| grep deploy.sh` |

## Security notes
- Keep the SSH **private key** only on the bot server (`chmod 600`). Rotate it if it is ever pasted anywhere.
- Slack tokens live only in the env file (`chmod 600`).
- Do not give the deploy user passwordless full sudo. Make the app run as the deploy user instead.

## Possible next steps
Live per-stage updates in Slack (one Ansible task per stage), `/deploy status|rollback|logs`, confirm buttons,
a deploy history, and other app types (Spring Boot, Flutter web) as separate playbooks.
