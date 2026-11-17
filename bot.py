"""Slack deploy bot (Socket Mode: outbound websocket only, no inbound ports).

Slash command:
  /deploy list                      -> show deployable projects
  /deploy <project> [branch]        -> deploy (branch defaults to project's default_branch)

Live status is written into ONE Slack message that is updated as steps progress.
"""
import logging
import os
import re
import threading

import yaml
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

from run_deploy import run_deploy

BASE = os.environ.get("DEPLOYBOT_DIR", "/opt/dakshabot")
PROJECTS_FILE = f"{BASE}/project/projects.yml"
USERS_FILE = f"{BASE}/users.yml"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("dakshabot")

app = App(token=os.environ["SLACK_BOT_TOKEN"])
_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


def _load(path):
    with open(path) as f:
        return yaml.safe_load(f) or {}


def _lock_for(project: str) -> threading.Lock:
    with _locks_guard:
        return _locks.setdefault(project, threading.Lock())


def _is_allowed(user_id: str, project_cfg: dict) -> bool:
    groups = _load(USERS_FILE).get("groups", {})
    return any(user_id in groups.get(g, []) for g in project_cfg.get("allowed", []))


def _deploy_worker(client, channel, user_id, project, cfg, branch):
    lock = _lock_for(project)
    if not lock.acquire(blocking=False):
        client.chat_postMessage(channel=channel, text=f":warning: A deploy of `{project}` is already running.")
        return
    try:
        head = f"*Deploy `{project}`* branch `{branch or cfg['default_branch']}` by <@{user_id}>"
        lines: list[str] = []
        msg = client.chat_postMessage(channel=channel, text=head)
        ts = msg["ts"]

        def post(text):
            # collapse "[running] X" into "[done] X" so each step is one line
            label = text.split("]", 1)[1].strip()
            if text.startswith(("[done]", "[FAILED]")):
                for i, l in enumerate(lines):
                    # replace the matching "[running] <label>" line
                    if l.startswith("[running]") and label.startswith(l.split("]", 1)[1].strip()):
                        lines[i] = text
                        break
                else:
                    lines.append(text)
            else:
                lines.append(text)
            body = head + "\n```" + "\n".join(lines)[-2800:] + "```"
            try:
                client.chat_update(channel=channel, ts=ts, text=body)
            except Exception:
                log.exception("chat_update failed")

        log.info("deploy start project=%s branch=%s user=%s", project, branch, user_id)
        status, report = run_deploy(project, cfg["host"], branch, post)
        log.info("deploy end project=%s status=%s", project, status)
        icon = ":white_check_mark:" if status == "successful" else ":x:"
        client.chat_postMessage(channel=channel, thread_ts=ts,
                                text=f"{icon} `{project}` deploy *{status}*")
        if report:
            try:   # needs the files:write scope
                client.files_upload_v2(channel=channel, thread_ts=ts, content=report,
                                       filename=f"{project}_deploy_error.log",
                                       title=f"{project} deploy error report")
            except Exception:
                log.exception("file upload failed, posting as text")
                for i in range(0, len(report), 2800):
                    client.chat_postMessage(channel=channel, thread_ts=ts,
                                            text="```" + report[i:i + 2800] + "```")
    except Exception as e:
        log.exception("deploy crashed")
        client.chat_postMessage(channel=channel, text=f":x: Bot error: `{e}`")
    finally:
        lock.release()


@app.command("/deploy")
def deploy_cmd(ack, command, client):
    ack()  # must answer within 3s; real work runs in a thread
    user, channel = command["user_id"], command["channel_id"]
    parts = (command.get("text") or "").split()
    projects = _load(PROJECTS_FILE).get("projects", {})

    if not parts or parts[0] == "list":
        rows = "\n".join(f"• `{n}` ({c.get('type')}, {c['host']}, default `{c['default_branch']}`)"
                         for n, c in projects.items())
        client.chat_postEphemeral(channel=channel, user=user,
                                  text=f"Usage: `/deploy <project> [branch]`\n{rows}")
        return

    project = parts[0]
    branch = parts[1] if len(parts) > 1 else ""
    cfg = projects.get(project)
    if branch and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,99}", branch):
        client.chat_postEphemeral(channel=channel, user=user, text=f"Invalid branch name `{branch}`.")
        return
    if not cfg:
        client.chat_postEphemeral(channel=channel, user=user, text=f"Unknown project `{project}`. Try `/deploy list`.")
        return
    if not _is_allowed(user, cfg):
        log.warning("denied user=%s project=%s", user, project)
        client.chat_postEphemeral(channel=channel, user=user, text=":no_entry: You're not allowed to deploy this project.")
        return
    threading.Thread(target=_deploy_worker, args=(client, channel, user, project, cfg, branch), daemon=True).start()


if __name__ == "__main__":
    SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"]).start()
