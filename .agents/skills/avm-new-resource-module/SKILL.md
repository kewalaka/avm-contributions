---
name: avm-new-resource-module
description: Create a new AVM Terraform resource module from an Azure resource type using tfmodmake.
glob: "**/*.tf,**/*.tfvars,**/*.tf.json,**/*.tfvars.json"
---

# AVM New Resource Module Creation

This skill provides a workflow for creating a **net-new** AVM resource module using `tfmodmake`. It covers the initial creation and integration steps.

For all other AVM development tasks (fixing issues, adding features, running tests), use the AVM Terraform Module Development skill, available here:

```bash
npx skills add Azure/terraform-azurerm-avm-template -s avm-terraform-module-development -y
```

## Step 0: Prerequisites

Install `tfmodmake` from source:

```bash
git clone https://github.com/matt-FFFFFF/tfmodmake.git /tmp/tfmodmake-src
cd /tmp/tfmodmake-src && go build -o /usr/local/bin/tfmodmake ./cmd/tfmodmake
```

Confirm: `tfmodmake --help`

## Step 1: Scaffold the resource with tfmodmake

```bash
mkdir -p /tmp/<resource-slug>-module && cd /tmp/<resource-slug>-module
tfmodmake discover versions -resource "<ResourceType>"
# Get the API version from the last command's output, then run:
tfmodmake gen avm -resource "<ResourceType>" -include-preview --api-version "<api-version>"
```

Where `<ResourceType>` is the ARM resource type, e.g. `Microsoft.App/agents`.

This generates in the output dir:
- `main.tf` — `azapi_resource` scaffold
- `variables.tf` — all resource properties as typed variables
- `locals.tf` — `resource_body` local reconstructing the JSON body
- `outputs.tf` — resource id/name + selected computed read-only fields
- `terraform.tf` — provider version constraints
- `main.interfaces.tf` — AVM interfaces (lock, role assignments, diagnostic settings, private endpoints, telemetry)
- `main.<child>.tf` + `variables.<child>.tf` + `modules/<child>/` — for each child resource type
- `modules/*` - submodules for each child resource type, with their own terraform files.

Inspect these files carefully before proceeding. The generated code is a starting point — not production-ready.

## Step 2: Assess what to keep vs replace

Review the generated files against the AVM template. Key decisions:

| Item | Action |
|---|---|
| `azapi_resource` in `main.tf` | Keep — copy into template's `main.tf` |
| `locals.tf` `resource_body` | Keep — copy into template's `locals.tf` |
| `variables.tf` (resource-specific vars) | Keep — merge into template's `variables.tf` |
| `outputs.tf` | Keep — replace template stub outputs, but remove outputs for excluded `response_export_values` fields |
| `terraform.tf` | Keep provider versions, update `required_version` to `~> 1.12` if ephemeral vars needed |
| `main.interfaces.tf` | switch to use the latest version on the registry (not feat/prepv1), use this for all interfaces (e.g. locks, private endpoints, etc) except diagnostic settings, which should use azurerm for now. |
| Private endpoints variable | Remove if the resource type doesn't support PE (check ARM docs) |
| `customer_managed_key` variable | Remove if the resource type doesn't support CMK |
| Child submodules | Keep — see Step 4 |

**Provider rules:**
- ALL resource components → `azapi` provider
- Diagnostic settings → `azurerm_monitor_diagnostic_setting` (keep azurerm; AVM diagnostic interface via azapi is not yet stable)
- Lock, role assignments → `avm-utl-interfaces` latest release.

Useful references (from `avm-terraform-module-development`):
- AzAPI patterns + schema lookup: `../avm-terraform-module-development/references/AzAPI.md`
- Provider schema queries (incl. ephemeral): `../avm-terraform-module-development/references/tfpluginschema.md`
- Testing guidance: `../avm-terraform-module-development/references/terraform-test.md` and `../avm-terraform-module-development/references/example-test.md`

## Step 3: Integrate into the AVM template root module

### `terraform.tf`
```hcl
terraform {
  required_version = "~> 1.12"  # required for ephemeral variables
  required_providers {
    azapi   = { source = "Azure/azapi",       version = "~> 2.7" }
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    modtm   = { source = "azure/modtm",       version = "~> 0.3" }
    random  = { source = "hashicorp/random",  version = "~> 3.5" }
  }
}
```

### `main.tf`

```hcl
## IMPORTANT: Do not use `data` sources inside modules to resolve parent IDs.
## This is a known source of "known after apply" / planning-time issues.
## Require the caller to pass the parent resource ID (e.g., the resource group ID).

resource "azapi_resource" "this" {
  type      = "<ResourceType>@<api-version>"
  name      = var.name
  parent_id = var.parent_id
  location  = var.location
  body      = local.resource_body
  tags      = var.tags
  # ... sensitive_body, identity, response_export_values
}
```

When defining `response_export_values`, do **not** include these fields:

```hcl
apiVersion
properties.deploymentError
properties.runningState
systemData
type
```

Also remove any generated outputs that depend on those excluded fields.

### `variables.tf` (parent)

```hcl
variable "parent_id" {
  type        = string
  description = "The parent resource ID. For resource-group-scoped resources, pass the resource group ID from the caller (e.g., azurerm_resource_group.this.id)."
}
```

**`schema_validation_enabled = false` is required ONLY IF the API version is not yet in the azapi provider's embedded schema**.  Apply this only if required as selectively as possible, since it disables all schema validation and can allow invalid configurations to be deployed.  Report this to the user so it can be reported upstream.

### Sensitive / ephemeral variables

Use `sensitive_body` + `ephemeral = true` for secrets (e.g. connection strings, keys):

```hcl
# variables.tf
variable "connection_key" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "The connection key (ephemeral — not stored in state)."
  default     = null
}

variable "connection_key_version" {
  type        = string
  description = "Opaque version token; change to trigger re-read of connection_key."
  default     = null
}

# main.tf — inside azapi_resource
sensitive_body = {
  properties = {
    someConfiguration = {
      connectionKey = var.connection_key
    }
  }
}
sensitive_body_version = {
  "properties.someConfiguration.connectionKey" = var.connection_key_version
}
```

### `main.interfaces.tf` (locks + role assignments)

If your module supports locks and role assignments, prefer `avm-utl-interfaces` (registry) over hand-rolled patterns. `tfmodmake` may generate an interfaces file; ensure it uses a released registry version (not a git `feat/*` ref).

```hcl
module "avm_interfaces" {
  source  = "Azure/avm-utl-interfaces/azure"
  # Use the latest release.
  version = "0.6.0"

  lock                                      = var.lock
  role_assignment_definition_lookup_enabled = var.role_assignment_definition_lookup_enabled
  role_assignment_definition_scope          = coalesce(var.role_assignment_definition_scope, var.parent_id)
  role_assignments                          = var.role_assignments
}

resource "azapi_resource" "lock" {
  count = module.avm_interfaces.lock_azapi != null ? 1 : 0

  name      = module.avm_interfaces.lock_azapi.name
  parent_id = azapi_resource.this.id
  type      = module.avm_interfaces.lock_azapi.type
  body      = module.avm_interfaces.lock_azapi.body

  create_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  delete_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  read_headers   = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  update_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
}

resource "azapi_resource" "role_assignments" {
  for_each = module.avm_interfaces.role_assignments_azapi

  name      = each.value.name
  parent_id = azapi_resource.this.id
  type      = each.value.type
  body      = each.value.body

  create_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  delete_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  read_headers   = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  update_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
}
```

### `main.privateendpoint.tf`

If the resource does not support private endpoints, replace the template content with:

```hcl
# Private endpoints are not supported for this resource type.
```

Remove `private_endpoints`, `private_endpoints_manage_dns_zone_group` from `variables.tf` and the `private_endpoint_application_security_group_associations` local from `locals.tf`.

### `_header.md` (root)

Update from the template placeholder to describe the actual resource:

```markdown
# terraform-azurerm-avm-res-<service>-<resource>

This module deploys <ResourceFriendlyName> (`<ResourceType>`), providing <brief description>.
```

**NEVER edit `README.md` directly** — it is auto-generated by terraform-docs via pre-commit.

## Step 4: Child submodules

Check the Azure REST API to confirm whether the submodule is read only.  Submodules should be singular (e.g., `agent` not `agents`).  Wire each submodule from the root using a `main.<child>.tf` file that calls the child module, passing necessary shared inputs.

**Post-generation checklist for each submodule:**

- [ ] Add `sensitive_body` blocks for any secret properties
- [ ] Verify `enable_telemetry` is passed through from root (default to root's value)
- [ ] Verify shared inputs are wired and used (commonly `tags`, `enable_telemetry`, and `location` **only if the child resource supports it**) to avoid tflint “unused variable” failures
- [ ] Create `modules/<name>/_header.md` — one-liner + minimal direct-call example:

```markdown
# <name>

This submodule manages a `<ChildResourceType>` as a child of `<ParentResourceType>`. Example: `module "<name>" { source = "../../modules/<name>"; name = "my-<name>"; parent_id = module.<root>.resource_id }`
```

- [ ] Create `modules/<name>/_footer.md` — copy from root `_footer.md`
- [ ] Create `modules/<name>/.terraform-docs.yml` if the root has one (copy and adjust path)

## Step 5: Default example

`examples/default/main.tf` must:
- Match root module's `required_version` and all providers
- Include `provider "azapi" {}` alongside `provider "azurerm" { features {} }`
- Use `module.naming.<type>.name_unique` for the resource name (or `resource_group.name_unique` as fallback if no naming entry exists)
- Keep `module "regions"` + `random_integer.region_index` + `module "naming"` + `azurerm_resource_group.this`
- Pass `parent_id = azurerm_resource_group.this.id` into the root module (do not look it up via `data` sources)

`examples/default/variables.tf` — keep only `enable_telemetry`.

Create `examples/default/_header.md` and `examples/default/_footer.md` (copy from root).

## Step 6: Pre-commit

```bash
PORCH_NO_TUI=1 ./avm pre-commit
```

If you are running this inside an agent (or any environment with a small output/context window), prefer capturing full output to a log file and only printing the tail on failure:

```bash
PORCH_NO_TUI=1 ./avm pre-commit > /tmp/avm-pre-commit.log 2>&1 || tail -n 200 /tmp/avm-pre-commit.log
```

This runs terraform-docs (generates `README.md` for root and all submodules), terraform fmt, and other linters. **Always run before committing.**

> ⚠️ If the `./avm` wrapper hangs in TUI mode, use `PORCH_NO_TUI=1` env var. Do NOT use `NO_PORCH` (that disables porch entirely). The correct env var was confirmed to be `PORCH_NO_TUI=1` in the `avm-terraform-module-development` skill — use that.

### Troubleshooting: `./avm pr-check` gets `Killed` (macOS)

If Porch is getting SIGKILL’d during the “Copy to temp” phase and Make prints something like:

`make: *** [avmmakefile:30: pr-check] Killed`

Check for oversized generated Terraform directories (commonly `./examples/default/.terraform`, sometimes hundreds of MB). Porch’s PR check runs multiple sub-steps and copies the whole repo to temp each time; a huge `.terraform` can trip Docker Desktop’s memory/IO limits on macOS.

Fix: delete the large `.terraform` directories (e.g., `rm -rf ./examples/default/.terraform **/.terraform`) and re-run `./avm pr-check`.

### Troubleshooting: tflint “unused variable” in submodules

If `./avm pr-check` (or `tflint`) flags unused variables in a submodule, it usually means the module defines inputs like `enable_telemetry` / `tags` / `location` but the submodule call or submodule implementation doesn’t actually use them.

Fix: either wire the values into the module call (e.g., in `main.<child>.tf`) and ensure the submodule consumes them, OR remove the variables/pass-through entirely when they don’t apply (e.g., omit `location` for non-regional child resources).

## Step 7: Validate

```bash
cd examples/default
terraform init
terraform validate
```

Agent-friendly variant (capture full output, show only the tail on failure):

```bash
cd examples/default
terraform init > /tmp/tf-init.log 2>&1 || tail -n 200 /tmp/tf-init.log
terraform validate > /tmp/tf-validate.log 2>&1 || tail -n 200 /tmp/tf-validate.log
```

`terraform plan` will fail with auth errors (expected — no Azure credentials). The goal is confirming the config parses cleanly. A successful plan output showing N resources to create (with auth error at the end) is a pass.

## Step 8: Commit

```bash
git add .
git commit -m "feat: implement AVM <ResourceFriendlyName> module (<ResourceType>)

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

## Step 9: PR check (MANDATORY)

After committing, always run:

```bash
PORCH_NO_TUI=1 ./avm pr-check
```

Agent-friendly variant (capture full output, show only the tail on failure):

```bash
PORCH_NO_TUI=1 ./avm pr-check > /tmp/avm-pr-check.log 2>&1 || tail -n 200 /tmp/avm-pr-check.log
```

## Step 10: Push and open a PR

```bash
git push -u origin HEAD
```

---

## Appendix

### Orchestration guidance

This is a multi-file, multi-phase task. Use the orchestrator pattern:

For the broader AVM development workflow (branching, tests, pre-commit, pr-check), follow the `avm-terraform-module-development` skill.

1. Launch a **root module + submodule subagent** for Steps 2–4
2. Wait for completion, spot-check `main.tf` and `modules/*/main.tf`
3. Launch a **default example subagent** for Step 5
4. Run pre-commit yourself (Step 6) — short command, no delegation needed
5. Launch a **tf-plan subagent** for Step 7 — it should fix any schema errors it finds and commit

Do NOT attempt all phases in a single agent context — file counts and diffs will overflow context.

### Resource naming module guidance

- **Naming module entries**: `Azure/naming/azurerm` doesn't have entries for all resource types (e.g. `Microsoft.App/agents`). When there is no entry, `module.naming.resource_group.name_unique` is an acceptable short-term stand-in for examples. Track https://github.com/Azure/terraform-azurerm-naming for new entries.
