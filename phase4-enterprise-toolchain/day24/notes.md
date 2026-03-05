# Day 24 — Terraform Infrastructure as Code

## Goals
- Install Terraform and use the Kubernetes provider
- Provision the monitoring namespace and Prometheus prerequisites via Terraform
- Demonstrate `plan → apply` workflow
- Show drift detection and automatic correction

---

## Why Terraform for Kubernetes?

Terraform adds value beyond `kubectl apply`:
- **State tracking**: Terraform knows what it manages (no orphaned resources)
- **Drift detection**: `terraform plan` shows diff between declared vs actual
- **Dependency ordering**: Resources created in correct order (namespace before ServiceAccount)
- **Lifecycle management**: `terraform destroy` removes exactly what was created
- **Multi-provider**: Same tool manages K8s resources + cloud infra (VM, DNS, load balancer)

---

## Installation

```bash
# Via HashiCorp APT repo
wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform
terraform version
# Terraform v1.14.6
```

---

## Provider Configuration (OKD)

Key gotcha: the Kubernetes provider must use `insecure = true` for OKD's self-signed cert, and explicit `host` + `token` (rather than kubeconfig auto-detection):

```hcl
provider "kubernetes" {
  host     = "https://api.crc.testing:6443"
  token    = "<oc whoami -t>"
  insecure = true   # OKD self-signed wildcard cert
}
```

---

## Resources Provisioned

```
$ terraform state list

kubernetes_cluster_role.prometheus
kubernetes_cluster_role_binding.prometheus
kubernetes_config_map.prometheus_config
kubernetes_namespace.monitoring
kubernetes_persistent_volume_claim.prometheus_storage
kubernetes_service_account.prometheus
```

### What each resource does

| Resource | Purpose |
|----------|---------|
| `kubernetes_namespace.monitoring` | Namespace with `managed-by=terraform` label |
| `kubernetes_service_account.prometheus` | Identity for Prometheus pod |
| `kubernetes_cluster_role.prometheus` | Read access to pods/nodes/services cluster-wide |
| `kubernetes_cluster_role_binding.prometheus` | Bind SA to ClusterRole |
| `kubernetes_config_map.prometheus_config` | Prometheus scrape configuration |
| `kubernetes_persistent_volume_claim.prometheus_storage` | 5Gi TSDB storage for Prometheus |

---

## Workflow

```bash
# Initialize providers
terraform init

# Preview changes (no-op if already applied)
terraform plan

# Apply with confirmation
terraform apply

# Apply without interactive prompt (for CI)
terraform apply -auto-approve

# Tear down everything in state
terraform destroy -auto-approve
```

---

## Demo Results

### Plan output

```
Plan: 6 to add, 0 to change, 0 to destroy.
```

### Apply output

```
kubernetes_cluster_role.prometheus: Creating...
kubernetes_namespace.monitoring: Creating...
kubernetes_cluster_role.prometheus: Creation complete [id=prometheus-scraper]
kubernetes_namespace.monitoring: Modifications complete [id=monitoring]
kubernetes_service_account.prometheus: Creation complete [id=monitoring/prometheus-sa]
kubernetes_config_map.prometheus_config: Creation complete [id=monitoring/prometheus-config]
kubernetes_persistent_volume_claim.prometheus_storage: Creation complete [id=monitoring/prometheus-storage]
kubernetes_cluster_role_binding.prometheus: Creation complete [id=prometheus-scraper-binding]

Apply complete! Resources: 4 added, 1 changed, 0 destroyed.
```

---

## Drift Detection Demo

```bash
# Engineer adds unauthorized label directly (outside Terraform)
oc label namespace monitoring unauthorized-change=hotfix

# Terraform detects the drift
terraform plan
# Output:
#   ~ update in-place
#   # kubernetes_namespace.monitoring will be updated in-place
#       - "unauthorized-change" = "hotfix" -> null
#
# Plan: 0 to add, 2 to change, 0 to destroy.

# Terraform corrects it
terraform apply -auto-approve
# Apply complete! Resources: 0 added, 2 changed, 0 destroyed.
```

This is the core value of IaC: **configuration drift is detected and corrected automatically**, preventing "works on my machine" surprises.

---

## State File (local)

```json
// terraform.tfstate (excerpt)
{
  "version": 4,
  "resources": [
    {
      "type": "kubernetes_namespace",
      "name": "monitoring",
      "instances": [
        {
          "attributes": {
            "id": "monitoring",
            "metadata": [{ "name": "monitoring", "labels": { "managed-by": "terraform" } }]
          }
        }
      ]
    }
  ]
}
```

**In production:** Store state in a remote backend with locking:
```hcl
terraform {
  backend "s3" {
    bucket         = "my-tf-state"
    key            = "openshift/monitoring/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-state-lock"
  }
}
```

---

## Lab Challenge: Backend Config Changed Error

When changing the `backend` block, Terraform requires `terraform init -reconfigure`. Fixed by:
1. Removing the explicit `backend "local"` block (Terraform defaults to local state in current directory)
2. Running `terraform init` fresh

---

## What's Next (Day 27)

The resources provisioned today (monitoring namespace, prometheus-sa, ClusterRole, ConfigMap, PVC) are the prerequisites for deploying Prometheus + Grafana in Day 27. Terraform provisions the infrastructure; Helm/manifests will deploy the applications on top.
