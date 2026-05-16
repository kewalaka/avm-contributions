# avm-contributions

A personal repository that acts as a persistent registry and CI orchestrator for
[Azure Verified Module (AVM)](https://azure.github.io/Azure-Verified-Modules/) contributions
in flight.

External contributors cannot trigger CI in the Azure org — the AVM guidance recommends
running checks locally, but that makes evidencing the work harder.  This repository
re-hosts the same checks as GitHub Actions workflows so external contributors can run
them against multiple modules and share publicly-visible CI results with the AVM team.

The [`avm-contributor-agent`](https://github.com/kewalaka/avm-contributor-agent) can also
trigger these workflows directly via `repository_dispatch` — no manual YAML editing required.

---

## How it works

1. `modules.yaml` lists every module (and branch) you are working on.
2. Four reusable workflows read that registry and fan out one job per module.
3. Alternatively, any workflow can be triggered via `repository_dispatch` from an agent —
   bypassing `modules.yaml` entirely.

| Workflow | Trigger | Azure credentials? | What it runs |
|---|---|---|---|
| **Checks** | push · dispatch | ✓ | `make pre-commit` → `make pr-check` (recent AVM modules also run Well-Architected/conftest checks here) |
| **E2E tests** | workflow_dispatch · repository_dispatch | ✓ | `make test-examples` on recent AVM modules; legacy `make test-example` fallback |
| **Terraform tests** | dispatch · push | unit: ✗ / integration: ✓ | `make tf-test-unit` / `make tf-test-integration` |

All workflows accept an optional **`module_filter`**
`workflow_dispatch` input so you can target a single module without editing `modules.yaml`.

---

## Prerequisites

### Tools (local development)

- [Docker](https://docs.docker.com/get-docker/) or Podman — used by the `./avm` helper
  and pulled automatically by the workflows.
- Azure CLI (`az`) — for local `az login` before running e2e tests.

### GitHub environments and secrets

Three workflows deploy real Azure resources and are gated behind a GitHub Actions
**environment** named **`test`**.

| Workflow | Environment | Azure secrets needed |
|---|---|---|
| `checks.yml` | `test` | `ARM_*` (pr-check runs terraform plan) |
| `e2e-tests.yml` | `test` | `ARM_*` |
| `terraform-tests.yml` (integration job) | `test` | `ARM_*` |
| `upgrade-tests.yml` | `test` | `ARM_*` |

Create the `test` environment in *Settings → Environments* and optionally add protection
rules (e.g. required reviewers) before any Azure credentials are used.

The `test` environment **does not need its own secrets** — the workflows read from
**repository-level secrets** (Settings → Secrets and variables → Actions):

| Secret | Required | Description |
|---|---|---|
| `ARM_TENANT_ID` | ✓ | Microsoft Entra ID tenant ID |
| `ARM_SUBSCRIPTION_ID` | ✓ | Azure subscription to deploy into |
| `ARM_CLIENT_ID` | ✓ | Client ID of the User-Assigned Managed Identity |
| `AGENT_DISPATCH_TOKEN` | ✓ | PAT with `contents: write` on `avm-contributor-agent` (for CI callbacks) |
| `ARM_TENANT_ID_OVERRIDE` | optional | Alternative tenant for modules that need it |
| `ARM_SUBSCRIPTION_ID_OVERRIDE` | optional | Alternative subscription |
| `ARM_CLIENT_ID_OVERRIDE` | optional | Alternative managed identity |

#### Setting up Azure OIDC and GitHub secrets automatically

Run [`scripts/setup-azure-oidc.sh`](./scripts/setup-azure-oidc.sh) to:

1. Create a User-Assigned Managed Identity in Azure.
2. Assign it `Contributor` + `Role Based Access Control Administrator` on the subscription.
3. Add a federated credential scoped to the `test` environment in this repo.
4. Create the `test` GitHub environment.
5. Set all required GitHub repository secrets.

```bash
# Prerequisites: az CLI logged in, gh CLI authenticated
./scripts/setup-azure-oidc.sh
```

See the script for optional environment variables to override the defaults (resource group
name, location, identity name, etc.).

---

## Adding a module

Edit [`modules.yaml`](./modules.yaml) and add an entry:

```yaml
modules:
  - source: <github-owner>/<repo-name>   # required
    branch: <branch-name>                # optional – omit to use the default branch
    name: <friendly-name>                # optional – defaults to the repo name
```

Example:

```yaml
modules:
  - source: kewalaka/terraform-azurerm-avm-res-app-managedenvironment
    branch: kewalaka/fold-tfmodmake-into-module

  - source: kewalaka/terraform-azurerm-avm-res-storage-storageaccount
    branch: feature/add-lifecycle-policy
    name: storage-account
```

Commit and push — every workflow will automatically pick up the new entry on its next run.

---

## Running workflows

### Via GitHub UI

1. Navigate to **Actions** in this repository.
2. Select the workflow you want to run.
3. Click **Run workflow**.
4. Optionally fill in the `module_filter` field to run only one module (substring match
   on the `source` field, e.g. `managedenvironment`).

### Via GitHub CLI

```bash
# Run checks (pre-commit + pr-check) for all modules
gh workflow run checks.yml

# Run e2e tests for a specific module
gh workflow run e2e-tests.yml -f module_filter=managedenvironment
```

### Via repository_dispatch (agent / API)

Any caller with a `repo` scoped PAT (or `contents: write` from another Actions workflow)
can trigger CI without touching `modules.yaml`:

```bash
# Run checks on a specific branch (with agent callback)
gh api repos/kewalaka/avm-contributions/dispatches \
  --method POST \
  --field event_type=module-checks \
  --field 'client_payload[source]=kewalaka/terraform-azurerm-avm-res-foo-bar' \
  --field 'client_payload[branch]=feature/my-fix' \
  --field 'client_payload[callback_repo]=kewalaka/avm-contributor-agent'

# Run terraform unit tests only
gh api repos/kewalaka/avm-contributions/dispatches \
  --method POST \
  --field event_type=module-tf-test \
  --field 'client_payload[source]=kewalaka/terraform-azurerm-avm-res-foo-bar' \
  --field 'client_payload[branch]=feature/my-fix' \
  --field 'client_payload[test_type]=unit' \
  --field 'client_payload[callback_repo]=kewalaka/avm-contributor-agent'

# Trigger e2e tests (requires "test" environment approval)
gh api repos/kewalaka/avm-contributions/dispatches \
  --method POST \
  --field event_type=module-e2e \
  --field 'client_payload[source]=kewalaka/terraform-azurerm-avm-res-foo-bar' \
  --field 'client_payload[branch]=feature/my-fix' \
  --field 'client_payload[callback_repo]=kewalaka/avm-contributor-agent'

# Trigger upgrade tests
gh api repos/kewalaka/avm-contributions/dispatches \
  -X POST \
  -f 'event_type=module-upgrade' \
  -f 'client_payload[dispatch_id]=manual-001' \
  -f 'client_payload[upstream_repo]=Azure/terraform-azurerm-avm-res-app-managedenvironment' \
  -f 'client_payload[fork_repo]=kewalaka/terraform-azurerm-avm-res-app-managedenvironment' \
  -f 'client_payload[base_ref]=main' \
  -f 'client_payload[head_ref]=kewalaka/fold-tfmodmake-into-module' \
  -f 'client_payload[example]=default'  
```

`gh api --field client_payload='{"...":"..."}'` sends `client_payload` as a JSON
string, not an object. Use nested `client_payload[...]` fields as shown above.

**Dispatch event types:**

| `event_type` | Workflow | Payload fields |
|---|---|---|
| `module-checks` | `checks.yml` | `source` (required), `branch` (optional), `callback_repo` (optional) |
| `module-e2e` | `e2e-tests.yml` | `source` (required), `branch` (optional), `callback_repo` (optional) |
| `module-tf-test` | `terraform-tests.yml` | `source` (required), `branch` (optional), `test_type` (optional: `both`/`unit`/`integration`), `callback_repo` (optional) |

**`callback_repo`** — when set to `"owner/repo"`, the workflow fires a `repository_dispatch`
event of type `ci-result` back to that repository when the job completes (success or
failure).  The target repo must have an `AGENT_DISPATCH_TOKEN` secret configured in
`kewalaka/avm-contributions` (Settings → Secrets) with `contents: write` permission on the
callback repo.  The `ci-result` payload contains:

```json
{
  "status":   "success | failure",
  "module":   "kewalaka/terraform-azurerm-avm-res-foo-bar",
  "branch":   "feature/my-fix",
  "workflow": "checks | e2e | unit-tests | integration-tests",
  "run_url":  "https://github.com/kewalaka/avm-contributions/actions/runs/..."
}
```

For `module-e2e` and `module-tf-test`, the `source` field must belong to an allowed
GitHub org (`kewalaka` or `Azure`).  The `test` environment gate provides a second layer
of protection before any Azure credentials are used.

---

## Local development (equivalent commands)

These are the same steps the workflows automate.  Run them from inside the cloned module
directory.

### 1. Pre-commit

```bash
./avm pre-commit
# If files changed:
git add -A && git commit -m "chore: pre-commit fixes" && git push
```

### 2. PR-check

```bash
./avm pr-check
```

### 3. End-to-end tests

```bash
az login
./avm test-examples
```

### 4. Unit tests

```bash
./avm tf-test-unit
```

### 5. Integration tests

```bash
az login
./avm tf-test-integration
```

---

## Repository structure

```
avm-contributions/
├── README.md                    # this file
├── modules.yaml                 # registry of in-progress modules
├── scripts/
│   └── setup-azure-oidc.sh      # one-shot Azure + GitHub setup
└── .github/
    └── workflows/
        ├── checks.yml               # pre-commit + pr-check (replaces pre-commit.yml + pr-check.yml)
        ├── e2e-tests.yml            # runs e2e tests (needs Azure credentials)
        ├── terraform-tests.yml     # runs unit + integration terraform tests
        └── upgrade-tests.yml       # tests module upgrades (apply base → upgrade → verify)
```

## Upgrade test flow

```text
apply_base  (BASE module + BASE example config)  → create real resources
    ↓
copy state to head workspace
    ↓
init_upgrade (HEAD module)
    ↓
plan_A  (HEAD module + BASE example config)    ← "does upgrading the module break existing configs?"
    │                                             THIS is the breaking change signal
    │
    ├─ destroys or replacements present? → BREAKING CHANGE ✗
    │
    └─ neither? → NO BREAKING CHANGE ✓
         ↓
plan_B  (HEAD module + HEAD example config)    ← "does the new example also work?"
         │
         └─ optional apply_head if B is clean
    ↓
destroy   HEAD module if apply_head was attempted (captures partial-apply state)
           BASE module if apply_head was skipped (avoids HEAD validation risk)
```
