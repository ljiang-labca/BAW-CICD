# BAW CICD Pipeline — Automated Snapshot Deployment

> Automated CI/CD pipeline that deploys IBM Business Automation Workflow (BAW) snapshots from Workflow Center to a QA server using GitHub Actions and a self-hosted runner.

---

## How It Works — High Level

```
BAW Workflow Center
    │
    │  1. Developer creates & names a snapshot
    │  2. BAW pushes a descriptor JSON to this GitHub repo
    ▼
GitHub Repository  (workflow/**/*_descriptor.json)
    │
    │  3. Push event triggers GitHub Actions workflow
    ▼
GitHub Actions (self-hosted runner on your network)
    │
    │  4. Parses app acronym & snapshot name from the descriptor
    │  5. Authenticates with Workflow Center REST API
    │  6. Requests offline package generation
    │  7. Downloads the generated .zip package to the runner
    │  8. Authenticates with QA BAW Server REST API
    │  9. Uploads & installs the package on QA
    │  10. Polls async queue until install completes
    ▼
QA BAW Server  — snapshot is live
    │
    │  11. GitHub sends email to QA team for sign-off
    ▼
Manual Approval Gate  (QA-Verification environment)
    │
    │  12. QA reviewer approves via email link or GitHub UI
    ▼
Pipeline Complete ✅
```

---

## Prerequisites

### BAW Side

#### 1. Enable Git integration on Workflow Center
In your BAW Workflow Center administration console:
- Navigate to **Admin** → **Workflow Center Settings** → **Git Integration**
- Configure the GitHub repo URL: `https://github.com/<org>/BAW-CICD.git`
- Provide a GitHub Personal Access Token (PAT) with `repo` write scope
- Set the target branch to `main`
- Set the push path to `workflow/` — BAW will push descriptor JSON files here

#### 2. Create a named snapshot
When a developer is ready to promote to QA:
- Open the process app in Workflow Center
- Create a snapshot with a meaningful acronym (e.g. `RHS1802`)
- Use the **"Push to Git"** action — this triggers the pipeline automatically

#### 3. Ensure the Offline Server is configured
The pipeline requests an offline package targeting a named server acronym (`QA_SERVER` by default).
- In Workflow Center → **Servers**, ensure the QA server is registered with the acronym matching `OFFLINE_SERVER_ACRONYM` in the workflow env vars

---

### GitHub Side

#### 1. Repository secrets
Go to **Settings → Secrets and variables → Actions** and add the following secrets:

| Secret Name | Description |
|---|---|
| `BAW_CENTER_HOST` | Hostname of the BAW Workflow Center (e.g. `center.example.com`) |
| `BAW_CENTER_PORT` | Port of the Workflow Center REST API (e.g. `9443`) |
| `BAW_CENTER_USER` | BAW admin username for Workflow Center |
| `BAW_CENTER_PASSWORD` | BAW admin password for Workflow Center |
| `BAW_QA_HOST` | Hostname of the QA BAW server |
| `BAW_QA_PORT` | Port of the QA BAW server REST API (e.g. `9443`) |
| `BAW_QA_USER` | BAW admin username for QA server |
| `BAW_QA_PASSWORD` | BAW admin password for QA server |

#### 2. Self-hosted runner
The pipeline runs on a **self-hosted runner** — a Linux machine on your internal network that can reach both the Workflow Center and QA BAW server.

To register a runner:
1. Go to **Settings → Actions → Runners → New self-hosted runner**
2. Follow the GitHub instructions to install and start the runner agent on your Linux machine
3. Ensure the runner machine has the following installed:
   - `bash`, `curl`, `jq`, `file`, `git`

#### 3. QA-Verification environment
This environment provides the manual approval gate after deployment.

1. Go to **Settings → Environments → New environment**
2. Name it exactly: `QA-Verification`
3. Under **Protection rules**, enable **Required reviewers**
4. Add the GitHub usernames of your QA team members who will approve deployments
5. Optionally set a **deployment timeout** (the pipeline default is 24 hours)

#### 4. Workflow environment variables
Two non-secret settings are defined at the top of [`.github/workflows/poc-qa-deploy.yml`](.github/workflows/poc-qa-deploy.yml):

| Variable | Default | Description |
|---|---|---|
| `VERIFY_SSL` | `"false"` | Set to `"true"` when real TLS certificates are in place |
| `OFFLINE_SERVER_ACRONYM` | `"QA_SERVER"` | Must match the server acronym registered in Workflow Center |

---

## Repository Structure

```
BAW-CICD/
├── .github/
│   ├── workflows/
│   │   └── poc-qa-deploy.yml     # GitHub Actions workflow definition
│   └── scripts/
│       └── poc-qa-deploy.sh      # Deployment shell script (runs on the runner)
├── workflow/
│   └── <APP_ACRONYM>/
│       └── <SNAPSHOT>_descriptor.json   # Pushed here by BAW Workflow Center
├── README.md                     # This file
└── TROUBLESHOOTING.md            # Troubleshooting guide
```

---

## Triggering the Pipeline

### Automatic (normal operation)
Push a snapshot from BAW Workflow Center using the Git integration. BAW writes a `*_descriptor.json` file to the `workflow/` folder, which triggers the pipeline automatically.

### Manual (testing / re-deployment)
1. Go to **Actions** → **BAW PoC - QA Deployment and Verification**
2. Click **Run workflow**
3. Enter the **Process App Acronym** (e.g. `HSS`) and **Snapshot Acronym** (e.g. `RHS1802`)
4. Click the green **Run workflow** button

---

## Approving a Deployment

After a successful install on the QA server:
1. GitHub sends an **email notification** to all required reviewers configured on the `QA-Verification` environment
2. Click the link in the email — it takes you directly to the approval page
3. Click **Review deployments** → check **QA-Verification** → **Approve and deploy**

Alternatively, navigate to: **Actions → [the running workflow] → qa-testing-signoff job → Review deployments**

---

## Runner Logs

Every pipeline run writes a detailed log to the runner machine at:
```
~/baw-cicd-logs/deploy_<YYYYMMDD_HHMMSS>.log
```

On failure, all API response JSON files are preserved alongside the log:
```
~/baw-cicd-logs/center_login_<timestamp>.json
~/baw-cicd-logs/qa_queue_status_<timestamp>.json
# etc.
```

These are invaluable for diagnosing issues — the log file path is printed at the top of every GitHub Actions run output.

---

## See Also

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — Common issues and how to resolve them
- [BAW REST API documentation](https://www.ibm.com/docs/en/baw) — IBM BAW REST API reference
