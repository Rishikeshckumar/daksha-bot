# Slack Deploy Bot (Slack + Ansible + shell scripts)

Deploy Java/Gradle-style apps from Slack with one command, with automatic rollback.
The bot runs on a server in a **private subnet** and needs **no inbound ports**: Slack Socket Mode
opens an outbound websocket.

```
/deploy myapp [branch]
  -> Slack (Socket Mode, outbound websocket)
  -> bot.py          checks project, branch name, user permission, per-project lock
  -> run_deploy.py   starts Ansible (playbooks/deploy_app.yml)
  -> Ansible         SSH to the app server, runs: bash deploy.sh <branch>
  -> deploy.sh       stop -> backup -> clone -> [pre-build] -> build -> start -> health
        |- success: exit 0, no log left behind
        '- failure: error report + rollback.sh (restore previous build) -> exit 1 (or 2)
  -> bot posts the steps, a result, and on failure the error report as a file
```

## Repo layout
```
bot.py                  Slack handler (/deploy list | /deploy <project> [branch])
run_deploy.py           runs the playbook via ansible-runner, parses deploy.sh output
playbooks/deploy_app.yml  runs deploy.sh on the target host
app-scripts/            copied to each app server, inside each project folder
  deploy.sh rollback.sh build.sh start.sh stop.sh health.sh
setup_server.sh         one-time setup of the bot server
```
Live config (hosts, projects, users, tokens, `project.env`) is **not** in the repo.
Create it with the `cat >` blocks in step 5.

## Requirements
- Bot server: Ubuntu 22.04+, outbound HTTPS (443) to Slack, SSH (22) to the app servers.
- App servers: SSH, `bash`, `git`, `java`, `pgrep`, `flock` (util-linux), Python 3 (for Ansible).
- A Slack workspace where you can create an app (the Free plan works).

## 1. Create the Slack app
1. https://api.slack.com/apps -> **Create New App -> From scratch**.
2. **Socket Mode**: enable; create an app-level token with scope `connections:write` (`xapp-...`).
3. **Slash Commands -> Create New Command**: `/deploy`, any placeholder Request URL, usage hint `<project> [branch] | list`.
4. **OAuth & Permissions -> Bot Token Scopes**: `commands`, `chat:write`, `chat:write.public`, `files:write`.
5. **Install to Workspace** (reinstall after any scope/command change). Copy the Bot token (`xoxb-...`).
6. Each person's Slack member ID: profile -> ⋮ -> *Copy member ID*.

## 2. Set up the bot server
```bash
git clone <this-repo-url> deploybot && cd deploybot
sudo bash setup_server.sh
# custom layout (e.g. keep everything under /data/infra):
# sudo env DEPLOYBOT_DIR=/data/infra/deploybot BOT_USER=deploybot GROUP=ops bash setup_server.sh
```
It creates the bot user, the venv, an SSH key and a systemd unit, then prints the **public** key.
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
The app must run as this user, not root, or `stop.sh` cannot stop it. If it runs as root today,
stop it once as root, `chown -R deploy:` the folder, and start it again with `start.sh`.

## 4. Install the scripts in each project folder (app server)
```bash
# from the bot server / your machine
scp app-scripts/*.sh deploy@app-server-1:/opt/apps/myapp/
```

## 5. Create the config files
Placeholders only: replace the values.

**Bot server, `$B` = `/opt/deploybot`:**
```bash
B=/opt/deploybot

# Slack tokens (chmod 600, owner = bot user; setup_server.sh creates this file)
sudo tee $B/deploybot.env >/dev/null <<'EOF'
SLACK_BOT_TOKEN=xoxb-your-bot-token
SLACK_APP_TOKEN=xapp-your-app-token
EOF
sudo chmod 600 $B/deploybot.env

# Ansible inventory: one line per app server
sudo tee $B/inventory/hosts.ini >/dev/null <<'EOF'
[app_servers]
app-server-1 ansible_host=192.0.2.10 ansible_user=deploy

[all:vars]
ansible_ssh_private_key_file=/opt/deploybot/home/.ssh/id_ed25519
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30'
ansible_python_interpreter=/usr/bin/python3
EOF

# Project registry: one block per project. `host` must match a name in hosts.ini
sudo tee $B/project/projects.yml >/dev/null <<'EOF'
projects:
  myapp:
    host: app-server-1
    type: app
    base_dir: /opt/apps/myapp        # folder that holds deploy.sh and project.env
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

sudo chown -R deploybot:deploybot $B/inventory $B/project $B/users.yml
```

**App server, `/opt/apps/myapp/project.env`** (the only file that differs per project):
```bash
sudo -u deploy tee /opt/apps/myapp/project.env >/dev/null <<'EOF'
APP_DIR=$BASE_DIR/app                              # where the repo is cloned
JAR_NAME=$(basename "$BASE_DIR").jar               # unique jar name, visible in ps
JAR=$APP_DIR/build/libs/$JAR_NAME
REPO=https://git.example.com/org/myapp.git
DEFAULT_BRANCH=main
BUILD_CMD="./gradlew --no-daemon clean jar"
BUILT_JAR=build/libs/app.jar                       # what BUILD_CMD produces (relative to APP_DIR)
PRE_BUILD_CMD=""                                   # optional, runs in APP_DIR before the build
XMS=512m
XMX=1g
JAVA_OPTS="-XX:+UseG1GC"                           # extra JVM flags
STABLE_SECONDS=90                                  # health check: process must stay alive this long
APP_LOG=logs/app.log                               # relative to APP_DIR, included in failure reports
#export GRADLE_USER_HOME=/opt/gradle_home          # shared cache if the deploy user has an empty ~/.gradle
EOF
```

## 6. Test, in this order
```bash
B=/opt/deploybot

# a) SSH + Ansible reach the host (expect "pong")
sudo -u deploybot env HOME=$B/home $B/venv/bin/ansible -i $B/inventory/hosts.ini app-server-1 -m ping

# b) on the app server: real deploy by hand, then a failure test (expect rollback + a report)
cd /opt/apps/myapp
sudo -u deploy bash deploy.sh
sudo -u deploy bash deploy.sh no-such-branch

# c) through Ansible, without Slack
sudo -u deploybot env HOME=$B/home $B/venv/bin/ansible-playbook -i $B/inventory/hosts.ini \
  $B/project/playbooks/deploy_app.yml -e project=myapp -e target=app-server-1 -e branch=main

# d) start the bot and use it from Slack
sudo systemctl enable --now deploybot
journalctl -u deploybot -f          # look for "Bolt app is running!"
```

## 7. Usage
| Slack command | What it does |
|---|---|
| `/deploy` or `/deploy list` | list projects |
| `/deploy myapp` | deploy the default branch |
| `/deploy myapp feature-x` | deploy a branch |

Server side:
```bash
sudo systemctl status|restart deploybot      # restart after changing bot.py, run_deploy.py or the env file
journalctl -u deploybot -n 50 --no-pager
cd /opt/apps/myapp && sudo -u deploy bash rollback.sh   # manual rollback to the previous build
```
`projects.yml` and `users.yml` are re-read on every command, so no restart is needed for those.

## How it works
- **deploy.sh stages:** stop, backup (`app` -> `app_bk`), clone, optional `PRE_BUILD_CMD`, build, start, health.
- **Rollback:** any failed stage calls `rollback.sh`: the failed build is kept as `app_err_<ts>` (2 newest kept),
  `app_bk` is restored and started. Exit codes: `0` deployed, `1` failed and rolled back, `2` rollback failed.
- **Health check:** the process (found by its unique jar path) must stay alive for `STABLE_SECONDS`.
  It detects crashes during startup, not a process that is alive but broken.
- **Logs:** a successful deploy leaves no log. A failed one writes `logs/error_<ts>.log` (last 10 kept); the bot
  uploads the same report to Slack.
- **Locks:** `flock` on `.deploy.lock` per project folder on the server, plus an in-memory lock per project in the bot.
- **Input safety:** branch names are validated; the bot runs only named playbooks, never free-form commands.

## Troubleshooting
| Symptom | Cause / fix |
|---|---|
| Slackbot: "`/deploy` is not a valid command" | the slash command was never created in the Slack app (step 1.3); reinstall the app |
| `/deploy` shows nothing, log is empty | Socket Mode off, or app not reinstalled after changes |
| `Permission denied (publickey)` in Ansible | public key missing in the deploy user's `authorized_keys`, or wrong permissions (step 3) |
| `Connection timed out` | port 22 blocked: security group / firewall |
| `Operation not permitted` in stop.sh | the app runs as another user (e.g. root): stop it once, `chown -R`, restart as the deploy user |
| Prompt for a password during deploy | `sudo` inside a script, or git asking for credentials: make both non-interactive |
| `another deploy is already running` | the lock works; wait, or check `ps -ef \| grep deploy.sh` |
| Gradle cannot find a plugin offline | the deploy user's `~/.gradle` is empty: set `GRADLE_USER_HOME` to a shared cache |
| `project.env missing or incomplete` | create it in the project folder (step 5) |

## Security notes
- Keep the SSH **private key** only on the bot server (`chmod 600`). Rotate it if it is ever pasted anywhere.
- Slack tokens live only in the env file (`chmod 600`).
- Do not give the deploy user passwordless full sudo. Make the app run as the deploy user instead.
- Authorization is `allowed` groups in `projects.yml` mapped to Slack IDs in `users.yml`.

## Possible next steps
Live per-stage updates in Slack, `/deploy status|rollback|logs`, confirm buttons, a deploy history, and other app
types (Spring Boot, Flutter web) as separate playbooks.
