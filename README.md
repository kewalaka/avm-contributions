# avm-contributions

A personal repository that acts as a persistent registry and CI orchestrator for
[Azure Verified Module (AVM)](https://azure.github.io/Azure-Verified-Modules/) contributions
in flight.

External contributors cannot trigger CI in the Azure org — the AVM guidance recommends
running checks locally, but that makes evidencing the work harder.  This repository
re-hosts the same checks as GitHub Actions workflows so external contributors can run
them against multiple modules and share publicly-visible CI results with the AVM team.

An autonomous `tf-module-developer-agent` can also trigger these workflows directly via
`repository_dispatch` — no manual YAML editing required.

---

## How it works

1. `modules.yaml` lists every module (and branch) you are working on.
2. Four reusable workflows read that registry and fan out one job per module.
3. Alternatively, any workflow can be triggered via `repository_dispatch` from an agent —
   bypassing `modules.yaml` entirely.

| Workflow | Trigger | Azure credentials? | What it runs |
|---|---|---|---|
| **Checks** | push · dispatch | ✗ | `make pre-commit` → `make pr-check` (sequential; pr-check skipped if pre-commit fails) |
| **E2E tests** | dispatch only | ✓ | conftest → `make test-example` for every example |
| **Terraform tests** | dispatch · push | unit: ✗ / integration: ✓ | `make tf-test-unit` / `make tf-test-integration` |
| **Build image** | push (Dockerfile) · dispatch | ✗ | builds `ghcr.io/kewalaka/azterraform:latest` |

All workflows except **Build image** accept an optional **`module_filter`**
`workflow_dispatch` input so you can target a single module without editing `modules.yaml`.

---

## First-time setup

Before running any checks or tests, build the extended Docker image:

```bash
# Trigger via GitHub CLI
gh workflow run build-image.yml
```

Or push a change to `.docker/Dockerfile` — the image builds automatically on merge to
`main`.  All other workflows use `ghcr.io/kewalaka/azterraform:latest`, which extends
the upstream `mcr.microsoft.com/azterraform:latest` with:

- **PowerShell Core (pwsh)** — present in `mcr.microsoft.com/avm:latest` but absent
  from `azterraform`; required by the pr-check porch config

---

## Prerequisites

### Tools (local development)

- [Docker](https://docs.docker.com/get-docker/) or Podman — used by the `./avm` helper
  and pulled automatically by the workflows.
- Azure CLI (`az`) — for local `az login` before running e2e tests.

### GitHub repository secrets

The e2e and integration-test workflows authenticate to Azure via
[OIDC (Workload Identity Federation)](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure).
Add the following **repository secrets** (Settings → Secrets and variables → Actions):

| Secret | Description |
|---|---|
| `ARM_TENANT_ID` | Microsoft Entra ID tenant ID |
| `ARM_SUBSCRIPTION_ID` | Azure subscription ID to deploy resources into |
| `ARM_CLIENT_ID` | Client (application) ID of the service principal / managed identity |

Optional overrides (used by some modules):

| Secret | Description |
|---|---|
| `ARM_TENANT_ID_OVERRIDE` | Alternative tenant ID |
| `ARM_SUBSCRIPTION_ID_OVERRIDE` | Alternative subscription ID |
| `ARM_CLIENT_ID_OVERRIDE` | Alternative client ID |

#### Setting up OIDC on Azure

```bash
# Create (or reuse) an app registration / managed identity and add a federated credential
# for this repository.  Replace the placeholders below.
APP_ID="<your-app-or-managed-identity-client-id>"
REPO="kewalaka/avm-contributions"

az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "{
    \"name\": \"avm-contributions-oidc\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${REPO}:environment:test\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
```

The workflows use a GitHub Actions **environment** named **`test`** to gate access to
the OIDC credentials.  Create this environment in *Settings → Environments* and (if
needed) add protection rules such as required reviewers.

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
# Run checks on a specific branch
gh api repos/kewalaka/avm-contributions/dispatches \
  --method POST \
  --field event_type=module-checks \
  --field client_payload='{"source":"kewalaka/terraform-azurerm-avm-res-foo-bar","branch":"feature/my-fix"}'

# Run terraform unit tests only
gh api repos/kewalaka/avm-contributions/dispatches \
  --method POST \
  --field event_type=module-tf-test \
  --field client_payload='{"source":"kewalaka/terraform-azurerm-avm-res-foo-bar","branch":"feature/my-fix","test_type":"unit"}'

# Trigger e2e tests (requires "test" environment approval)
gh api repos/kewalaka/avm-contributions/dispatches \
  --method POST \
  --field event_type=module-e2e \
  --field client_payload='{"source":"kewalaka/terraform-azurerm-avm-res-foo-bar","branch":"feature/my-fix"}'
```

**Dispatch event types:**

| `event_type` | Workflow | Payload fields |
|---|---|---|
| `module-checks` | `checks.yml` | `source` (required), `branch` (optional) |
| `module-e2e` | `e2e-tests.yml` | `source` (required), `branch` (optional) |
| `module-tf-test` | `terraform-tests.yml` | `source` (required), `branch` (optional), `test_type` (optional: `both`/`unit`/`integration`) |

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
cd examples/default
terraform init
terraform plan
terraform apply
terraform plan   # should show "0 changes" (idempotency check)
terraform destroy
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
├── .docker/
│   └── Dockerfile               # extends azterraform with newer porch + pwsh
└── .github/
    └── workflows/
        ├── build-image.yml          # builds ghcr.io/kewalaka/azterraform:latest
        ├── checks.yml               # pre-commit + pr-check (replaces pre-commit.yml + pr-check.yml)
        ├── e2e-tests.yml            # runs e2e tests (needs Azure credentials)
        └── terraform-tests.yml     # runs unit + integration terraform tests
```