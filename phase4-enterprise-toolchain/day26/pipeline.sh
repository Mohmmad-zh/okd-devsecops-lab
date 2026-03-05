#!/usr/bin/env bash
# Day 26 — Terraform + Ansible Pipeline
# Orchestrates infrastructure provisioning (Terraform) → configuration (Ansible)
#
# Usage: ./pipeline.sh [apply|destroy|verify]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="${1:-apply}"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[PIPELINE]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; exit 1; }

separator() { echo -e "\n${BLUE}════════════════════════════════════════════════════════${RESET}\n"; }

# ── Stage 0: Pre-flight checks ────────────────────────────────────────────────
preflight() {
  log "Running pre-flight checks..."

  command -v terraform >/dev/null 2>&1 || fail "terraform not found"
  command -v ansible-playbook >/dev/null 2>&1 || fail "ansible-playbook not found"
  command -v oc >/dev/null 2>&1 || fail "oc not found"

  oc whoami >/dev/null 2>&1 || fail "Not logged in to OKD. Run: oc login -u kubeadmin ..."

  OC_USER=$(oc whoami)
  ok "All prerequisites met. Connected as: ${OC_USER}"
}

# ── Stage 1: Terraform — provision infrastructure ─────────────────────────────
terraform_apply() {
  separator
  log "Stage 1: TERRAFORM — Provisioning aspnetapp-staging namespace"
  log "  Resources: Namespace, ServiceAccount, Role, RoleBinding, ResourceQuota"

  cd "$SCRIPT_DIR"

  # Capture token at runtime — avoids storing it in tfvars
  OC_TOKEN=$(oc whoami -t)

  terraform init -upgrade -input=false 2>&1 | grep -E "(Initializing|provider|complete)" || true
  echo ""

  log "Running terraform plan..."
  terraform plan \
    -var="oc_token=${OC_TOKEN}" \
    -out=tfplan \
    -input=false 2>&1

  log "Running terraform apply..."
  terraform apply \
    -input=false \
    tfplan

  separator
  log "Terraform outputs:"
  terraform output

  ok "Stage 1 complete: Infrastructure provisioned by Terraform"
}

# ── Stage 2: Ansible — configure application environment ──────────────────────
ansible_configure() {
  separator
  log "Stage 2: ANSIBLE — Configuring aspnetapp-staging"
  log "  Tasks: ConfigMap, NetworkPolicy, verification"

  cd "$SCRIPT_DIR"

  ansible-playbook \
    -i inventory.ini \
    configure_staging.yml \
    --diff

  ok "Stage 2 complete: Namespace configured by Ansible"
}

# ── Stage 3: Verify — end-to-end validation ───────────────────────────────────
verify_pipeline() {
  separator
  log "Stage 3: VERIFY — End-to-end pipeline validation"

  NS="aspnetapp-staging"

  echo ""
  log "Namespace labels (Terraform-managed):"
  oc get namespace "$NS" -o jsonpath='{.metadata.labels}' | python3 -m json.tool 2>/dev/null \
    || oc get namespace "$NS" --show-labels

  echo ""
  log "Resources in $NS:"
  oc get all,cm,quota,netpol,sa -n "$NS" 2>/dev/null || true

  echo ""
  log "ConfigMap data (Ansible-managed):"
  oc get configmap aspnetapp-config -n "$NS" -o yaml 2>/dev/null | grep -A20 "^data:" || true

  ok "Stage 3 complete: Pipeline verification passed"
}

# ── Destroy: clean up ─────────────────────────────────────────────────────────
terraform_destroy() {
  separator
  warn "DESTROY mode — removing all Terraform-managed resources"
  read -r -p "Are you sure? (yes/no): " confirm
  [[ "$confirm" == "yes" ]] || { log "Aborted."; exit 0; }

  OC_TOKEN=$(oc whoami -t)
  terraform destroy -var="oc_token=${OC_TOKEN}" -auto-approve
  ok "Destroyed aspnetapp-staging infrastructure"
}

# ── Main ──────────────────────────────────────────────────────────────────────
separator
log "Day 26 — Terraform + Ansible Pipeline"
log "Stage: ${STAGE}"
separator

case "$STAGE" in
  apply)
    preflight
    terraform_apply
    ansible_configure
    verify_pipeline
    separator
    ok "Pipeline complete: aspnetapp-staging is provisioned and configured"
    echo -e "\n${GREEN}Summary:${RESET}"
    echo "  Terraform: Namespace, SA, RBAC, ResourceQuota"
    echo "  Ansible:   ConfigMap (app config), NetworkPolicy"
    echo "  Next: Update Argo CD to deploy aspnetapp into aspnetapp-staging"
    ;;
  destroy)
    preflight
    terraform_destroy
    ;;
  verify)
    preflight
    verify_pipeline
    ;;
  *)
    echo "Usage: $0 [apply|destroy|verify]"
    exit 1
    ;;
esac
