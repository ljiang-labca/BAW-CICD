# Troubleshooting Guide — BAW CICD Pipeline

This guide covers the most common issues encountered running the BAW CICD pipeline and how to resolve them.

---

## Quick Diagnosis Checklist

When a run fails, check these in order:

1. **GitHub Actions UI** — go to Actions tab → failed run → expand the failing step
2. **Runner log file** — path printed at the top of every run: `~/baw-cicd-logs/deploy_<timestamp>.log`
3. **Preserved JSON files** — on failure, API response files are saved to `~/baw-cicd-logs/` with matching timestamp
4. **BAW server logs** — for server-side errors, check `SystemOut.log` on the relevant BAW server

---

## Issues by Stage

### Stage: Workflow Trigger

#### ❌ Pipeline did not trigger after BAW pushed to Git
**Symptom:** BAW pushed the descriptor JSON but no workflow run appeared in GitHub Actions.

**Checks:**
- Confirm the file was pushed to the `workflow/` folder and matches the path filter `workflow/**/*.json` in the workflow trigger
- Go to **Settings → Webhooks** and check the recent delivery history for the push event — a red `✗` means GitHub rejected or didn't receive it
- Confirm the workflow file exists on the `main` branch — a workflow only triggers from the branch it's on

---

#### ❌ Wrong snapshot picked up — old descriptor used instead of new one
**Symptom:** Log shows `PROCESS_APP_ACRONYM` and `SNAPSHOT_NAME` from a previous snapshot.

**Root cause:** `actions/checkout` uses `fetch-depth: 2` to enable `git diff HEAD~1 HEAD`. If this was changed to `fetch-depth: 1`, `HEAD~1` won't exist and the diff will silently fail.

**Fix:** Ensure the checkout step in the workflow has `fetch-depth: 2`.

---

### Stage: Parse BAW Payload Info

#### ❌ `fatal: bad revision 'HEAD~1'`
**Symptom:** Step fails with this git error.

**Root cause:** `fetch-depth` is set to `1` (or missing) in the checkout step.

**Fix:**
```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 2
```

---

#### ❌ `Failed to parse project_short_name or snapshot_acronym from JSON`
**Symptom:** The descriptor JSON was found but fields couldn't be extracted.

**Checks:**
- The step prints the full file contents on this error — check what keys the JSON actually has
- BAW may have changed the field names in a newer version
- Verify the JSON is valid (not truncated) by checking the file directly in the GitHub repo

---

### Stage: Workflow Center Authentication

#### ❌ `Workflow Center authentication failed (HTTP 401)`
**Checks:**
- Verify `BAW_CENTER_USER` and `BAW_CENTER_PASSWORD` secrets in **Settings → Secrets and variables → Actions**
- Confirm the user account is not locked on the BAW server
- Try the credentials manually using the Swagger UI at `https://<CENTER_HOST>:<CENTER_PORT>/ops/`

#### ❌ `Workflow Center authentication failed (HTTP 403)`
**Cause:** The user exists but does not have sufficient privileges.
**Fix:** Grant the BAW admin role to the service account used by the pipeline.

#### ❌ `Workflow Center authentication failed (HTTP 404)`
**Cause:** Wrong host or port, or the `/ops` endpoint is not available.
**Checks:**
- Verify `BAW_CENTER_HOST` and `BAW_CENTER_PORT` secrets
- Confirm the runner machine can reach the Workflow Center: `curl -k https://<host>:<port>/ops/system/login`

#### ❌ SSL errors / `curl: (60) SSL certificate problem`
**Cause:** `VERIFY_SSL` is set to `true` but BAW is using a self-signed certificate.
**Fix:** Either set `VERIFY_SSL: "false"` in the workflow env section, or install the BAW server's CA certificate on the runner machine.

---

### Stage: Package Generation

#### ❌ `Package generation initiation failed (HTTP 404)`
**Cause:** `PROCESS_APP_ACRONYM` or `SNAPSHOT_NAME` is wrong — the app or snapshot doesn't exist on Workflow Center.
**Fix:** Verify the acronyms match exactly (case-sensitive) what's shown in Workflow Center.

#### ❌ `Package generation initiation failed (HTTP 409)`
**Cause:** A package generation for this snapshot is already in progress.
**Fix:** Wait a few minutes and re-run. If it persists, check the Workflow Center system log.

#### ❌ `Timed out waiting for package to become ready after 20 minutes`
**Cause:** Package generation is taking longer than expected, or failed silently on the BAW side.
**Fix:** Check the Workflow Center system log for errors. Also verify the `OFFLINE_SERVER_ACRONYM` matches a registered server in Workflow Center → Servers.

---

### Stage: Package Download

#### ❌ `Archive download failed (HTTP 403)`
**Cause:** Missing or invalid `BPMCSRFToken` header — the session may have expired.
**Fix:** This is handled automatically by the script. If it recurs, check that the login step is completing successfully and the CSRF token is being extracted (look for `CSRF token acquired` in the log).

#### ❌ `Archive download failed (HTTP 404)`
**Cause:** The package was not generated successfully despite the generation step passing.
**Fix:** Check Workflow Center system log. Try manually generating the package from the Workflow Center UI.

#### ❌ `Archive download failed — file is empty`
**Cause:** Download completed with HTTP 200 but wrote an empty file.
**Fix:** Check available disk space on the runner: `df -h ~`. The default download path is `/tmp/downloaded_package.zip`.

---

### Stage: QA Server Authentication

Same checks as [Workflow Center Authentication](#stage-workflow-center-authentication) above — apply the same steps using `BAW_QA_HOST`, `BAW_QA_PORT`, `BAW_QA_USER`, `BAW_QA_PASSWORD`.

---

### Stage: QA Installation

#### ❌ `Deployment intake failed on QA Server (HTTP 403)`
**Cause:** Missing CSRF token on the upload request.
**Fix:** Verify the QA login step completed successfully — the CSRF token from QA login must be present.

#### ❌ `QA installation failed: CWTBG0737E`
**Cause:** Generic BAW server-side error. The real cause is in the QA server's `SystemOut.log`.

**Common root causes behind CWTBG0737E:**
| Root cause | What to look for in SystemOut.log |
|---|---|
| Snapshot already installed | `CWLLG2163E: The snapshot ... is already present on server` |
| Insufficient disk space on QA server | `No space left on device` |
| Database error during install | `SQLException` or `DB2` errors |
| Corrupt or incompatible package | `Invalid package format` |

**Action:** Share the `CWTBG0737E` error with your QA BAW administrator and ask them to check `SystemOut.log` at the timestamp shown in the pipeline log.

#### ❌ `QA installation state: failure` — no error message
**Fix:** Check the preserved `qa_queue_status_<timestamp>.json` file in `~/baw-cicd-logs/` on the runner for the full response body.

#### ❌ `Timed out waiting for QA installation after 30 minutes`
**Cause:** Installation is hanging on the QA server.
**Fix:** Check QA server health — disk space, database connectivity, available memory. Check `SystemOut.log` for thread dumps or deadlocks.

---

### Stage: Manual Approval

#### ❌ No approval email received
**Checks:**
- Confirm your GitHub username is listed under **Settings → Environments → QA-Verification → Required reviewers**
- Check your spam/junk folder
- Verify your GitHub account email is verified and notifications are enabled: **GitHub → Settings → Notifications → Actions**

#### ❌ Approval button is greyed out / not visible
**Cause:** You are not listed as a required reviewer for the `QA-Verification` environment.
**Fix:** Ask a repo admin to add your username to **Settings → Environments → QA-Verification → Required reviewers**.

#### ❌ Approval gate expired
**Cause:** The 24-hour timeout was reached without approval.
**Fix:** Re-run the pipeline from the Actions tab using **"Re-run failed jobs"** — this restarts only the `qa-testing-signoff` job without re-deploying.

---

## Reading Runner Logs

SSH into the runner machine and use these commands:

```bash
# List all run logs, newest first
ls -lt ~/baw-cicd-logs/

# Read the latest log
cat ~/baw-cicd-logs/deploy_<timestamp>.log

# Watch a run in progress (live tail)
tail -f ~/baw-cicd-logs/deploy_*.log | grep -v "^$"

# Check preserved API response files from a failed run
cat ~/baw-cicd-logs/qa_queue_status_<timestamp>.json

# Check disk space on the runner
df -h /tmp ~/baw-cicd-logs
```

---

## Checking BAW Server Logs

For errors like `CWTBG0737E`, ask the BAW administrator to check:

| Server | Log location |
|---|---|
| Workflow Center | `<WAS_PROFILE>/logs/<server>/SystemOut.log` |
| QA BAW Server | `<WAS_PROFILE>/logs/<server>/SystemOut.log` |

Filter the log around the timestamp shown in the pipeline run output.

---

## Runner Health Checks

If jobs never start (runner shows offline in GitHub):

```bash
# Check runner service status
cd ~/actions-runner && ./svc.sh status

# Check runner diagnostic logs
ls -lt ~/actions-runner/_diag/

# Restart the runner service
cd ~/actions-runner && ./svc.sh stop && ./svc.sh start
```

Ensure the runner machine can reach GitHub:
```bash
curl -I https://github.com
curl -I https://api.github.com
```

---

## Getting Help

- **Pipeline issues** → check this guide and the runner log file
- **BAW server errors (CWTBG*)** → escalate to your BAW administrator with the error code and timestamp
- **GitHub Actions issues** → see [GitHub Actions documentation](https://docs.github.com/en/actions)
- **BAW REST API reference** → see [IBM BAW documentation](https://www.ibm.com/docs/en/baw)
