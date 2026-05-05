---
name: avm-new-resource-module
description: >-
  Create a new AVM Terraform resource module from an Azure resource type using
  tfmodmake. USE THIS SKILL when a user wants to scaffold, initialise, or create
  a brand-new AVM resource module (e.g. "create an AVM module for
  Microsoft.App/agents", "start a new Terraform AVM module", "scaffold a module
  for <ARM resource type>", "make a new AVM module"). For fixing bugs, adding
  features, running tests, or doing PR checks on an existing module, use the
  avm-terraform-module-development skill instead.
---

# AVM New Resource Module Creation

This skill provides a workflow for creating a **net-new** AVM resource module using `tfmodmake`. It covers the initial creation and integration steps.

For all other AVM development tasks (fixing issues, adding features, running tests), use the AVM Terraform Module Development skill, available here:

```bash
npx skills add Azure/terraform-azurerm-avm-template -s avm-terraform-module-development -y
```

## Step 0: Prerequisites

Check whether `tfmodmake` is already available:

```bash
tfmodmake --help
```

If it is, skip to Step 1. If not, see `references/install-tfmodmake.md` for installation options.

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
| `main.interfaces.tf` | Switch to use the latest version on the registry (not feat/prepv1), use this for all interfaces (e.g. locks, role assignments, etc) except diagnostic settings, which should use azurerm for now. |
| Private endpoints variable | Remove if the resource type doesn't support PE. To check: look for a `privateEndpointConnections` child type in the ARM REST API docs for the resource, or check whether the resource appears in the [Azure Private Link supported services list](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview#private-link-resource). |
| `customer_managed_key` variable | Remove if the resource type doesn't support CMK. To check: look for `properties.encryption` in the ARM schema via `tfmodmake discover`. |
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

Passing `parent_id` as a variable (rather than resolving it via a `data` source) is a hard AVM rule — it avoids "known after apply" planning issues. The module must always require the caller to supply the parent resource ID. Do not add a `data` source to look it up.

The example below is drawn from `Microsoft.App/agents` — use it as a pattern, not a copy. Substitute your resource type, API version, `response_export_values`, and `sensitive_body` fields.

```hcl
resource "azapi_resource" "this" {
  # ① Fully-qualified ARM type including API version.
  type      = "Microsoft.App/agents@2026-01-01"
  location  = var.location
  name      = var.name
  # ② Always a variable — never resolved via a data source (causes "known after apply").
  parent_id = var.parent_id
  body      = local.resource_body

  # ③ Telemetry headers — keep this pattern exactly as shown.
  create_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  delete_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  read_headers   = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  update_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null

  # ④ Only export fields you actually surface as outputs.
  #    Never include: apiVersion, properties.deploymentError, properties.runningState, systemData, type
  response_export_values = [
    "identity.principalId",
    "identity.tenantId",
    "properties.agentEndpoint",
    "properties.agentIdentity.clientId",
    "properties.agentIdentity.enabled",
  ]

  # ⑤ Only add if the API version is absent from azapi's embedded schema.
  #    Disables all schema validation — apply selectively and report upstream.
  schema_validation_enabled = false

  # ⑥ Secrets go in sensitive_body so they are never written to state.
  sensitive_body = {
    properties = {
      incidentManagementConfiguration = var.incident_management_configuration == null ? null : {
        connectionKey = var.connection_key
      }
      logConfiguration = var.log_configuration == null ? null : {
        applicationInsightsConfiguration = {
          connectionString = var.connection_string
        }
      }
    }
  }
  # ⑦ Version tokens allow Terraform to detect secret rotation without storing the secret.
  sensitive_body_version = {
    "properties.incidentManagementConfiguration.connectionKey"                    = var.connection_key_version
    "properties.logConfiguration.applicationInsightsConfiguration.connectionString" = var.connection_string_version
  }

  tags = var.tags

  dynamic "identity" {
    for_each = local.managed_identities.system_assigned_user_assigned
    content {
      type         = identity.value.type
      identity_ids = identity.value.user_assigned_resource_ids
    }
  }
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

This variable is always required — it is the caller's responsibility to pass the resource group (or parent) ID. The module must never look it up internally.

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

### Module naming and repo setup

Derive `<service>` and `<resource>` from the ARM resource type by lower-casing the namespace and resource segments:

| ARM type | Module name |
|---|---|
| `Microsoft.App/agents` | `terraform-azurerm-avm-res-app-agent` |
| `Microsoft.Cache/redisEnterprise` | `terraform-azurerm-avm-res-cache-redisenterprise` |
| `Microsoft.Sql/servers` | `terraform-azurerm-avm-res-sql-server` |

The naming convention is: `terraform-azurerm-avm-res-<namespace-without-microsoft>-<resource-singular-lowercase>`.

Once the module repo is created and working, register it in this repo's `modules.yaml` file.

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

If pre-commit or pr-check fails unexpectedly (process killed, tflint unused-variable errors), see `references/troubleshooting.md`.

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
