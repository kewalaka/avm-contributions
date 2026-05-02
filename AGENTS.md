# AGENTS.md

Guidelines and learnings for AI agents working in this repository.

## Repository purpose

This repo holds GitHub Actions workflows that orchestrate Terraform module testing against Azure. Workflows are triggered by `repository_dispatch` events (agent-driven) and run Terraform inside the `mcr.microsoft.com/azterraform:avm-latest` Docker container.

## Workflow patterns — stay aligned with upstream AVM template

The upstream reference is [`Azure/terraform-azurerm-avm-template`](https://github.com/Azure/terraform-azurerm-avm-template), specifically `.github/workflows/test-examples-template.yml`. Before changing a workflow pattern, check whether it is intentionally matching upstream.

| Pattern | Upstream aligned? | Notes |
|---------|-------------------|-------|
| `prepare-credential.sh` sourced from `main` of `Azure/tfmod-scaffold` | Yes | Intentional — same as upstream AVM template |
| `ARM_*_OVERRIDE` secrets not passed as Docker `-e` flags | Yes | `prepare-credential.sh` reads them to configure OIDC; they do not need to be Docker env vars |
| Actions pinned to commit SHA | Yes | All `uses:` lines must include a commit SHA pin, e.g. `actions/checkout@<sha> # v6.0.2` |

## Security practices

- **Pre-checkout validation**: Validate `repository_dispatch` payload fields (required fields, org allowlist) *before* `actions/checkout` of an external repo. Validating after checkout allows an untrusted ref to influence the runner.
- **Allowed org list**: `fork_repo` must belong to a trusted GitHub org (currently `kewalaka`, `Azure`). Update `ALLOWED_ORGS` in the validation step if new orgs are added.
- **SHA-pin all actions**: Every `uses:` reference must be pinned to a full commit SHA with a version comment. Never leave tag-only pins (`@v4`) in merged workflow files.

## Destroy / cleanup reliability

- The destroy step must run if `apply_base` was **attempted** (`outcome != 'skipped'`), not only if it **succeeded**. A failed apply can still create real Azure resources.
- The destroy step checks for an initialised workspace before running; a missing workspace exits cleanly with a warning, so the broad condition does not cause spurious failures.

## Terraform state management

State lives locally in the runner workspace (`terraform.tfstate`). After `apply_base`, state is copied from `module-base` into `module-head` before upgrade steps run. Destroy prefers `module-head` (may have post-upgrade state) and falls back to `module-base`.

## Callback pattern

Workflows can notify an agent by sending a `repository_dispatch` to `callback_repo` (from payload). This requires `AGENT_DISPATCH_TOKEN` secret. If either is absent, the step skips silently.

## Adding new workflows

1. Model new workflows on the patterns in `upgrade-tests.yml` (payload validation, Docker run, destroy safety).
2. Pin all action SHAs — find the SHA for a tag at `https://github.com/<owner>/<repo>/commits/<tag>`.
3. Add `environment: test` to jobs that touch Azure resources (required for OIDC secret access).
4. Keep `strategy.fail-fast: false` for matrix jobs so all examples are attempted even if one fails.
