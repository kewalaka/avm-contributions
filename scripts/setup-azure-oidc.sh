#!/usr/bin/env bash
# setup-azure-oidc.sh
#
# Creates the Azure Managed Identity and federated credentials needed for
# OIDC-based GitHub Actions authentication, then sets the required GitHub
# repository secrets and creates the "test" environment.
#
# Prerequisites
#   - az CLI authenticated (az login)
#   - gh CLI authenticated (gh auth login)
#   - jq
#
# Override any of the variables below by exporting them before running:
#
#   export AZURE_SUBSCRIPTION_ID="<your-subscription-id>"
#   export AZURE_LOCATION="australiaeast"
#   ./scripts/setup-azure-oidc.sh

set -euo pipefail

# ── Configurable defaults ──────────────────────────────────────────────────────
GITHUB_REPO="${GITHUB_REPO:-kewalaka/avm-contributions}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
AZURE_TENANT_ID="${AZURE_TENANT_ID:-$(az account show --query tenantId -o tsv)}"
AZURE_LOCATION="${AZURE_LOCATION:-australiaeast}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-avm-contributions-oidc}"
IDENTITY_NAME="${IDENTITY_NAME:-id-avm-contributions-ci}"
GITHUB_ENVIRONMENT="${GITHUB_ENVIRONMENT:-test}"

# ── Callback token (optional — needed for CI result callbacks to avm-contributor-agent)
# Set AGENT_DISPATCH_TOKEN_VALUE to a PAT with contents:write on the callback repo,
# or leave blank to skip setting it.
AGENT_DISPATCH_TOKEN_VALUE="${AGENT_DISPATCH_TOKEN_VALUE:-}"

# ──────────────────────────────────────────────────────────────────────────────

echo "=== AVM Contributions — Azure OIDC setup ==="
echo ""
echo "  GitHub repo        : $GITHUB_REPO"
echo "  Azure subscription : $AZURE_SUBSCRIPTION_ID"
echo "  Azure tenant       : $AZURE_TENANT_ID"
echo "  Location           : $AZURE_LOCATION"
echo "  Resource group     : $RESOURCE_GROUP"
echo "  Identity name      : $IDENTITY_NAME"
echo "  GitHub environment : $GITHUB_ENVIRONMENT"
echo ""

# ── 1. Resource group ──────────────────────────────────────────────────────────
echo "--- 1/6  Ensuring resource group '$RESOURCE_GROUP' exists..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$AZURE_LOCATION" \
  --output none
echo "    OK"

# ── 2. User-Assigned Managed Identity ─────────────────────────────────────────
echo "--- 2/6  Creating / updating managed identity '$IDENTITY_NAME'..."
IDENTITY_JSON=$(az identity create \
  --name "$IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  --output json)

IDENTITY_CLIENT_ID=$(echo "$IDENTITY_JSON" | jq -r '.clientId')
IDENTITY_PRINCIPAL_ID=$(echo "$IDENTITY_JSON" | jq -r '.principalId')
IDENTITY_RESOURCE_ID=$(echo "$IDENTITY_JSON" | jq -r '.id')

echo "    Client ID    : $IDENTITY_CLIENT_ID"
echo "    Principal ID : $IDENTITY_PRINCIPAL_ID"

# ── 3. Role assignments ────────────────────────────────────────────────────────
SCOPE="/subscriptions/$AZURE_SUBSCRIPTION_ID"

echo "--- 3/6  Assigning roles on subscription scope..."

for ROLE in "Contributor" "Role Based Access Control Administrator"; do
  echo "    Assigning '$ROLE'..."
  # Idempotent — ignore 'already exists' errors
  az role assignment create \
    --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$ROLE" \
    --scope "$SCOPE" \
    --output none 2>/dev/null || echo "    (already assigned or no change needed)"
done
echo "    OK"

# ── 4. Federated credential for the GitHub Actions "test" environment ──────────
echo "--- 4/6  Adding federated credential (environment: $GITHUB_ENVIRONMENT)..."

FED_CRED_NAME="avm-contributions-${GITHUB_ENVIRONMENT}"
SUBJECT="repo:${GITHUB_REPO}:environment:${GITHUB_ENVIRONMENT}"

# Check if the federated credential already exists
EXISTING=$(az identity federated-credential list \
  --identity-name "$IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  --query "[?name=='$FED_CRED_NAME'] | length(@)" \
  --output tsv 2>/dev/null || echo "0")

if [ "${EXISTING}" -gt 0 ]; then
  echo "    Federated credential '$FED_CRED_NAME' already exists — updating..."
  az identity federated-credential update \
    --identity-name "$IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name "$FED_CRED_NAME" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "$SUBJECT" \
    --audiences "api://AzureADTokenExchange" \
    --output none
else
  az identity federated-credential create \
    --identity-name "$IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name "$FED_CRED_NAME" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "$SUBJECT" \
    --audiences "api://AzureADTokenExchange" \
    --output none
fi
echo "    Subject: $SUBJECT"
echo "    OK"

# ── 5. GitHub environment ──────────────────────────────────────────────────────
echo "--- 5/6  Creating GitHub environment '$GITHUB_ENVIRONMENT' in $GITHUB_REPO..."
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/${GITHUB_REPO}/environments/${GITHUB_ENVIRONMENT}" \
  --field wait_timer=0 \
  --silent || true
echo "    OK (visit Settings → Environments to add protection rules if desired)"

# ── 6. GitHub repository secrets ──────────────────────────────────────────────
echo "--- 6/6  Setting GitHub repository secrets..."

gh secret set ARM_TENANT_ID        --repo "$GITHUB_REPO" --body "$AZURE_TENANT_ID"
echo "    ARM_TENANT_ID         set"

gh secret set ARM_SUBSCRIPTION_ID  --repo "$GITHUB_REPO" --body "$AZURE_SUBSCRIPTION_ID"
echo "    ARM_SUBSCRIPTION_ID   set"

gh secret set ARM_CLIENT_ID        --repo "$GITHUB_REPO" --body "$IDENTITY_CLIENT_ID"
echo "    ARM_CLIENT_ID         set"

if [ -n "$AGENT_DISPATCH_TOKEN_VALUE" ]; then
  gh secret set AGENT_DISPATCH_TOKEN --repo "$GITHUB_REPO" --body "$AGENT_DISPATCH_TOKEN_VALUE"
  echo "    AGENT_DISPATCH_TOKEN  set"
else
  echo "    AGENT_DISPATCH_TOKEN  SKIPPED (set AGENT_DISPATCH_TOKEN_VALUE env var to configure)"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete ==="
echo ""
echo "  Managed identity resource : $IDENTITY_RESOURCE_ID"
echo "  ARM_CLIENT_ID             : $IDENTITY_CLIENT_ID"
echo "  ARM_TENANT_ID             : $AZURE_TENANT_ID"
echo "  ARM_SUBSCRIPTION_ID       : $AZURE_SUBSCRIPTION_ID"
echo ""
echo "Next steps:"
echo "  1. If you need override credentials (ARM_*_OVERRIDE), set those secrets manually."
echo "  2. Set AGENT_DISPATCH_TOKEN if you skipped it above:"
echo "       gh secret set AGENT_DISPATCH_TOKEN --repo $GITHUB_REPO --body <PAT>"
echo "  3. Visit https://github.com/$GITHUB_REPO/settings/environments to review"
echo "     protection rules on the '$GITHUB_ENVIRONMENT' environment."
