# Day 26 — Terraform + Ansible Pipeline

## Goals
- Combine Terraform (infrastructure) and Ansible (configuration) in a single pipeline
- Demonstrate the division of responsibility between the two tools
- Provision a staging namespace with Terraform, then configure it with Ansible
- Show Ansible verifying Terraform's work before proceeding

---

## Pipeline Architecture

```
┌─────────────────────────────────────────────────────────┐
│              Terraform + Ansible Pipeline               │
│                                                         │
│  Stage 1: PROVISION (Terraform)                         │
│  ─────────────────────────────────                      │
│  terraform apply -var="oc_token=$(oc whoami -t)"        │
│    → kubernetes_namespace "aspnetapp-staging"           │
│    → kubernetes_service_account "staging-deployer"      │
│    → kubernetes_role "staging-deployer"                 │
│    → kubernetes_role_binding                            │
│    → kubernetes_resource_quota (5 pods, 1Gi limit)      │
│                                                         │
│  Stage 2: CONFIGURE (Ansible)                           │
│  ─────────────────────────────────                      │
│  ansible-playbook configure_staging.yml                 │
│    → Verify ns managed-by=terraform (handshake check)   │
│    → Apply ConfigMap (ASPNETCORE_ENVIRONMENT=Staging)   │
│    → Verify ResourceQuota exists                        │
│    → Verify ServiceAccount exists                       │
│    → Pipeline summary                                   │
└─────────────────────────────────────────────────────────┘
```

---

## Division of Responsibility

| What | Terraform | Ansible |
|------|-----------|---------|
| Namespace | ✅ Creates | Verifies |
| ServiceAccount | ✅ Creates | Verifies |
| RBAC (Role + Binding) | ✅ Creates | — |
| ResourceQuota | ✅ Creates | Verifies |
| ConfigMap (app config) | — | ✅ Applies |
| State tracking | ✅ tfstate | — |
| Idempotency | ✅ plan/apply | ✅ changed_when |

**Rule of thumb:**
- Terraform owns **infrastructure** (namespaces, RBAC, quotas)
- Ansible owns **configuration** (ConfigMaps, environment-specific settings)

---

## Demo Results

### Stage 1: Terraform

```
$ terraform apply -auto-approve -var="oc_token=$(oc whoami -t)"

Apply complete! Resources: 0 added, 2 changed, 0 destroyed.

Outputs:
  staging_deployer_sa = "staging-deployer"
  staging_namespace = "aspnetapp-staging"
```

Resources provisioned:
- `aspnetapp-staging` namespace (labels: managed-by=terraform, environment=staging)
- `staging-deployer` ServiceAccount
- `staging-deployer` Role (deployments, services, pods CRUD)
- `staging-deployer-binding` RoleBinding
- `staging-quota` ResourceQuota (5 pods max, 1Gi memory limit)

### Stage 2: Ansible

```
$ ansible-playbook -i inventory.ini configure_staging.yml

TASK [Verify staging namespace was created by Terraform]
ok: [crc-vm]

TASK [Confirm namespace is Terraform-managed]
"msg": "Namespace 'aspnetapp-staging' is managed-by=terraform ✓"

TASK [Apply staging environment ConfigMap]
ok: [crc-vm]

TASK [Report ConfigMap status]
"msg": "ConfigMap: configmap/aspnetapp-config unchanged"

TASK [Report quota]
"msg": "ResourceQuota 'staging-quota': max pods=5 ✓"

TASK [Report ServiceAccount]
"msg": "ServiceAccount 'staging-deployer' exists ✓"

TASK [Pipeline summary]
"msg": [
    "Terraform provisioned: Namespace, SA, Role, RoleBinding, ResourceQuota",
    "Ansible configured: ConfigMap (env=Staging, version=a3f8b2c)",
    "Namespace aspnetapp-staging is ready"
]

PLAY RECAP
crc-vm: ok=9  changed=0  unreachable=0  failed=0  skipped=0
```

---

## Ansible Handshake Check

The Ansible playbook verifies it's operating on Terraform-managed infrastructure before making changes:

```yaml
- name: Verify staging namespace was created by Terraform
  ansible.builtin.command: >
    oc get namespace aspnetapp-staging
    -o jsonpath='{.metadata.labels.managed-by}'
  register: ns_managed_by
  changed_when: false
  failed_when: ns_managed_by.stdout != "terraform"   # ← FAIL if not Terraform-managed
```

This prevents Ansible from accidentally configuring manually-created or improperly-provisioned namespaces.

---

## OKD Annotation Drift Pattern

Both Day 24 and Day 26 showed that OKD automatically injects annotations on namespaces and ServiceAccounts:

```hcl
# Terraform detects these as "drift" (wants to remove):
- "openshift.io/sa.scc.mcs"                = "s0:c28,c17"
- "openshift.io/sa.scc.supplemental-groups" = "1000790000/10000"
- "openshift.io/sa.scc.uid-range"           = "1000790000/10000"
- "openshift.io/internal-registry-pull-secret-ref" = "staging-deployer-dockercfg-..."
```

**Production fix** — use `ignore_changes` for OKD-managed annotations:

```hcl
resource "kubernetes_namespace" "staging" {
  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].resource_version
    ]
  }
  ...
}
```

This is the correct production pattern to avoid Terraform fighting with OKD's automatic annotation injection on every apply.

---

## What's Next (Day 27)

Deploy Prometheus + Grafana to the `monitoring` namespace that Terraform provisioned in Day 24:
- Prometheus: scrapes aspnetapp metrics (the SA and RBAC are already in place)
- Grafana: dashboards showing request rate, latency, error rate
