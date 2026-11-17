"""Runs the Ansible deploy and streams step status to Slack.

`post(text)` updates the Slack status message.
Returns (status, report): status is "successful" | "failed"; report is the error report
text printed by deploy.sh between REPORT-BEGIN / REPORT-END (empty on success).
Layout expected by ansible-runner (DEPLOYBOT_DIR):
  <dir>/project/   -> playbooks/, projects.yml
  <dir>/inventory/ -> hosts.ini
"""
import os

import ansible_runner

BASE = os.environ.get("DEPLOYBOT_DIR", "/opt/deploybot")


def run_deploy(project: str, target: str, branch: str, post):
    report: list[str] = []

    def on_event(ev):
        data = ev.get("event_data", {})
        task = data.get("task", "")
        if not task.startswith("STEP deploy"):
            return True
        kind = ev.get("event")
        if kind == "playbook_on_task_start":
            post("[running] deploy.sh")
        elif kind in ("runner_on_ok", "runner_on_failed"):
            res = data.get("res", {})
            in_report = False
            for line in (res.get("stdout") or "").splitlines():
                if line == "REPORT-BEGIN":
                    in_report = True
                elif line == "REPORT-END":
                    in_report = False
                elif in_report:
                    report.append(line)
                elif line.startswith(("STEP:", "ROLLBACK", "FAILED", "REPORT", "OK:", "ERROR")):
                    post(f"[step]    {line}")
            if kind == "runner_on_ok":
                post("[done]    deploy.sh")
            else:
                rc = res.get("rc")
                note = " ROLLBACK ALSO FAILED - manual fix needed!" if rc == 2 else " (rolled back)" if rc == 1 else ""
                post(f"[FAILED]  deploy.sh rc={rc}{note}")
        return True

    r = ansible_runner.run(
        private_data_dir=BASE,
        playbook="playbooks/deploy_app.yml",
        extravars={"project": project, "target": target, "branch": branch},
        event_handler=on_event,
        quiet=True,
    )
    return r.status, "\n".join(report)
