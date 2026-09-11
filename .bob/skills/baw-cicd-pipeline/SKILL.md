---
name: baw-cicd-pipeline
description: Use when the user wants to set up, implement, troubleshoot, or extend a CI/CD pipeline for IBM Business Automation Workflow (BAW) using GitHub Actions and a self-hosted runner. Covers BAW Git integration setup, GitHub secrets and environments, the deployment shell script, REST API integration specifics, logging, and common failure patterns.
---

# BAW CICD Pipeline Skill

This skill guides you through setting up and maintaining an automated IBM BAW snapshot deployment pipeline using GitHub Actions and a self-hosted Linux runner. It is based on a validated PoC and documents the exact BAW REST API behaviours, common pitfalls, and troubleshooting patterns discovered during implementation.

Reference implementation: https://github.com/ljiang-labca/BAW-CICD

---

## When This Skill Applies

Activate this skill when the user wants to:
- Set up a new BAW CICD pipeline for a client
- Understand how to connect BAW Workflow Center to GitHub
- Implement or modify the deployment shell script
- Troubleshoot a failing pipeline run
- Extend the pipeline (new environments, notifications, rollback, etc.)

---

## Part 1 — Architecture Overview

The pipeline consists of:

1. **BAW Workflow Center** — pushes a `*_descriptor.json` file to a GitHub repo when a snapshot is created
2. **GitHub Repository** — stores descriptor files and all pipeline code; acts as the trigger source
3. **GitHub Actions** — orchestrates the workflow; manages secrets, step outputs, and environment gates
4. **Self-Hosted Runner** — Linux machine on the client network with access to both BAW servers; executes the shell script
5. **BAW REST API (`/ops`)** — used for login, package generation, download, and installation
6. **GitHub Environment (`QA-Verification`)** — provides the manual approval gate with email notification to reviewers

### Pipeline Flow
```
BAW Workflow Center
  → pushes *_descriptor.json to GitHub
    → GitHub Actions triggers (push path filter)
      → Self-hosted runner:
          1. Parse app acronym + snapshot name from descriptor (git diff, not find)
          2. Login to Workflow Center → get session cookie + CSRF token
          3. POST offline_package → wait 30s → GET install_package (download zip)
          4. Login to QA Server → get session cookie + CSRF token
          5. POST install (upload zip) → poll async url until state=success
      → QA-Verification environment gate
        → Email notification to reviewers
          → Reviewer approves → pipeline complete
```

---

## Part 2 — BAW Side Setup

### Enable Git Integration on Workflow Center
1. Navigate to **Admin → Workflow Center Settings → Git Integration**
2. Set the repository URL using the **GitHub API endpoint format** — NOT the regular clone URL:
   ```
   https://api.github.com/repos/<org>/<repo>
   ```
   ⚠️ Using `https://github.com/<org>/<repo>.git` will NOT work. Do not include `.git`.
3. Provide a GitHub **Personal Access Token (PAT)** with `repo` write scope
4. Set the target branch to `main`
5. Set the push path to `workflow/` — BAW pushes descriptor JSON files here

IBM documentation: https://www.ibm.com/docs/en/baw/25.0.x?topic=integration-integrating-github

### Register the Offline Server
The pipeline requests an offline package targeting a named server acronym.
- In Workflow Center → **Servers**, ensure the target server is registered
- The acronym must match `OFFLINE_SERVER_ACRONYM` in the workflow env vars (default: `QA_SERVER`)

---

## Part 3 — GitHub Side Setup

### Repository Secrets
Add these under **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `BAW_CENTER_HOST` | Workflow Center hostname |
| `BAW_CENTER_PORT` | Workflow Center REST API port (typically `9443`) |
| `BAW_CENTER_USER` | BAW admin username for Workflow Center |
| `BAW_CENTER_PASSWORD` | BAW admin password for Workflow Center |
| `BAW_QA_HOST` | QA BAW server hostname |
| `BAW_QA_PORT` | QA BAW server REST API port |
| `BAW_QA_USER` | BAW admin username for QA server |
| `BAW_QA_PASSWORD` | BAW admin password for QA server |

### Self-Hosted Runner
Register a Linux machine on the client network:
1. **Settings → Actions → Runners → New self-hosted runner**
2. Follow GitHub instructions to install the runner agent
3. Required tools on the runner: `bash`, `curl`, `jq`, `file`, `git`
4. Runner must reach both BAW servers on their REST API port
5. Runner writes logs to `~/baw-cicd-logs/` and downloads packages to `/tmp/`

### QA-Verification Environment
1. **Settings → Environments → New environment** — name it exactly `QA-Verification`
2. Enable **Required reviewers** and add QA team GitHub usernames
3. Set `timeout-minutes: 1440` (24h) on the job to prevent the queue from blocking indefinitely

### Workflow Top-Level Env Vars
Defined at the top of the workflow YAML — adjust per client:

| Variable | Default | Notes |
|---|---|---|
| `VERIFY_SSL` | `"false"` | Set to `"true"` when real TLS certificates are in place |
| `OFFLINE_SERVER_ACRONYM` | `"QA_SERVER"` | Must match the acronym in Workflow Center → Servers |

---

## Part 4 — Key Implementation Details

### Finding the Triggering Descriptor File
**Never use `find workflow -name "*_descriptor.json" | head -n 1`** — this picks files alphabetically and will use old snapshots when multiple exist.

Use `git diff` against the parent commit instead:
```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 2  # Required — HEAD~1 doesn't exist with depth 1

- run: |
    JSON_FILE=$(git diff --name-only --diff-filter=AM HEAD~1 HEAD \
      -- 'workflow/**/*_descriptor.json' | head -n 1)
```
`fetch-depth: 2` is mandatory — without it `HEAD~1` does not exist (shallow clone) and the diff silently fails.

### BAW REST API — Critical Behaviours

#### Login
```bash
curl -X POST \
  -u "${USER}:${PASSWORD}" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"refresh_groups": true, "requested_lifetime": 7200}' \
  "https://${HOST}:${PORT}/ops/system/login"
```
- Returns **HTTP 201** (not 200) on success
- Response body: `{"csrf_token": "eyJ...", "expiration": 7200}`
- Field is `csrf_token` — NOT `properties.BPMCSRFToken` (older BAW docs show the wrong name)

#### CSRF Token — Required on Every Request
The `BPMCSRFToken` header must be sent on **every** subsequent request — including GET requests and async queue polling. Missing it returns `CWTBG0651E`.

#### Offline Package Generation
```
POST /ops/std/bpm/containers/{APP}/versions/{SNAPSHOT}/offline_package?server={SERVER}
```
- Returns **HTTP 202** with `{"description": "..."}` — no queue ID, no poll URL
- Wait 30 seconds then attempt download directly

#### Package Download
```
GET /ops/std/bpm/containers/{APP}/versions/{SNAPSHOT}/install_package
```
- Requires `BPMCSRFToken` header and `accept: application/octet-stream`
- Missing the CSRF header returns **HTTP 403**

#### QA Installation
```
POST /ops/std/bpm/containers/install?inactive=false&caseOverwrite=true
```
- Upload as multipart: `-F "install_file=@${PACKAGE_PATH}"`
- Returns **HTTP 202** with `{"description": "...", "url": "https://.../ops/system/queue/N?key=..."}`
- Extract the `url` field and use it as the poll endpoint

#### Async Queue Polling
- Poll the `url` from the install response with `BPMCSRFToken` header
- Response uses `state` field (NOT `status`): `{"state": "running"|"success"|"failure", ...}`
- On failure: `{"state": "failure", "result": {"error": "CWTBG0737E: ..."}}`

### Logging
Every run writes to `~/baw-cicd-logs/deploy_YYYYMMDD_HHMMSS.log` on the runner.
On failure, API response JSON files are preserved with matching timestamps for post-mortem.
The log path is printed at the start of every GitHub Actions run.

---

## Part 5 — Common Errors and Fixes

| Error | Cause | Fix |
|---|---|---|
| Auth failed HTTP 401/403 | Wrong credentials or user locked | Verify secrets in GitHub Settings; test with Swagger UI |
| Auth failed HTTP 404 | Wrong host/port secret | Verify `BAW_CENTER_HOST` / `BAW_CENTER_PORT` secrets |
| `CWTBG0651E` | Missing `BPMCSRFToken` header | Add header to every curl call including queue polls |
| Queue ID null / poll hangs | Offline package endpoint returns no queue ID | Wait 30s then download directly — no queue to poll |
| Wrong snapshot deployed | `find` picks alphabetically, not by recency | Use `git diff HEAD~1 HEAD` with `fetch-depth: 2` |
| `fatal: bad revision 'HEAD~1'` | `fetch-depth: 1` (default checkout) | Add `fetch-depth: 2` to `actions/checkout` |
| Download HTTP 403 | Missing `BPMCSRFToken` on GET download | Add `-H "BPMCSRFToken: ${CSRF}"` to download curl |
| Poll always empty status | BAW uses `state` not `status` in queue responses | Read `.state // .status` in jq |
| `CWTBG0737E` on install | Generic server-side error | Check `SystemOut.log` on QA BAW server at the run timestamp |
| Snapshot already installed | BAW rejects duplicate install with CWTBG0737E | Remove or rename snapshot on QA server before re-running |
| SSL errors | Self-signed cert on BAW server | Set `VERIFY_SSL: "false"` or install CA cert on runner |

---

## Part 6 — Adapting for a Client

When setting up for a new client, work through these questions:

1. **How many environments?** (DEV / QA / STAGING / PROD) — one workflow per promotion stage is recommended
2. **Who are the approvers?** Add their GitHub usernames to the relevant GitHub Environment as required reviewers
3. **SSL certificates?** Self-signed → `VERIFY_SSL=false`; CA-signed → `VERIFY_SSL=true`
4. **Server acronym?** Confirm the offline server acronym registered in Workflow Center matches `OFFLINE_SERVER_ACRONYM`
5. **Runner machine ready?** Confirm `curl`, `jq`, `file`, `git` are installed and the machine can reach both BAW servers
6. **PAT scope?** The GitHub PAT used by BAW needs `repo` write scope (or `contents: write` for fine-grained tokens)
7. **Notifications beyond email?** Consider adding a Slack/Teams webhook step after the install success

---

## Part 7 — Roadmap / Extensions

- **Production promotion** — second workflow triggered by QA approval, with PROD approval gate
- **Multi-environment** — DEV → QA → STAGING → PROD with chained workflows
- **Slack/Teams notifications** — webhook call after install step
- **Automated smoke tests** — trigger a BAW process instance post-deploy and verify completion
- **Rollback** — undeploy previous snapshot on failure or QA rejection
- **Deployment dashboard** — GitHub Pages showing deployment history per environment
