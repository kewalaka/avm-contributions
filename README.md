# avm-contributions

A personal repository that acts as a persistent registry and CI orchestrator for
[Azure Verified Module (AVM)](https://azure.github.io/Azure-Verified-Modules/) contributions
in flight.

External contributors cannot trigger CI in the Azure org — the AVM guidance recommends
running checks locally, but that makes evidencing the work harder.  This repository
re-hosts the same checks as GitHub Actions workflows so external contributors can run
them against multiple modules and share publicly-visible CI results with the AVM team.

---

## How it works

1. `modules.yaml` lists every module (and branch) you are working on.
2. Four reusable workflows read that registry and fan out one job per module:

| Workflow | Trigger | Azure credentials? | What it runs |
|---|---|---|---|
| **Pre-commit** | push · dispatch | ✗ | `make pre-commit` (formatting, docs regeneration) |
| **PR-check** | push · dispatch | ✗ | `make pr-check` (static analysis / linting) |
| **E2E tests** | dispatch only | ✓ | conftest → `make test-example` for every example |
| **Terraform tests** | dispatch · push | unit: ✗ / integration: ✓ | `make tf-test-unit` / `make tf-test-integration` |

All four accept an optional **`module_filter`** `workflow_dispatch` input so you can
target a single module without editing `modules.yaml`.

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
# Run pre-commit for all modules
gh workflow run pre-commit.yml

# Run e2e tests for a specific module
gh workflow run e2e-tests.yml -f module_filter=managedenvironment
```

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
└── .github/
    └── workflows/
        ├── pre-commit.yml           # runs avm pre-commit for every module
        ├── pr-check.yml             # runs avm pr-check for every module
        ├── e2e-tests.yml            # runs e2e tests (needs Azure credentials)
        └── terraform-tests.yml     # runs unit + integration terraform tests
```