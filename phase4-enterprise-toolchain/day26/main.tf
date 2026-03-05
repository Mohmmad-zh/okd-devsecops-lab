terraform {
  required_version = ">= 1.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "kubernetes" {
  host     = "https://api.crc.testing:6443"
  token    = var.oc_token
  insecure = true
}

variable "oc_token" {
  description = "OKD service account token (from oc whoami -t)"
  type        = string
  sensitive   = true
}

# ──────────────────────────────────────────────────────────────
# Staging namespace — provisioned by Terraform
# ──────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "staging" {
  metadata {
    name = "aspnetapp-staging"
    labels = {
      "managed-by"  = "terraform"
      "environment" = "staging"
      "pipeline"    = "day26"
    }
    annotations = {
      "provisioned-at" = "day26-terraform-ansible-pipeline"
    }
  }
}

# ──────────────────────────────────────────────────────────────
# ServiceAccount for staging deployments
# ──────────────────────────────────────────────────────────────
resource "kubernetes_service_account" "staging_deployer" {
  metadata {
    name      = "staging-deployer"
    namespace = kubernetes_namespace.staging.metadata[0].name
    labels = {
      "managed-by" = "terraform"
    }
  }
}

# ──────────────────────────────────────────────────────────────
# Role: allow staging-deployer to manage deployments in staging
# ──────────────────────────────────────────────────────────────
resource "kubernetes_role" "staging_deployer" {
  metadata {
    name      = "staging-deployer"
    namespace = kubernetes_namespace.staging.metadata[0].name
    labels = {
      "managed-by" = "terraform"
    }
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "services", "configmaps"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "staging_deployer" {
  metadata {
    name      = "staging-deployer-binding"
    namespace = kubernetes_namespace.staging.metadata[0].name
    labels = {
      "managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.staging_deployer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.staging_deployer.metadata[0].name
    namespace = kubernetes_namespace.staging.metadata[0].name
  }
}

# ──────────────────────────────────────────────────────────────
# ResourceQuota — guard rails for staging
# ──────────────────────────────────────────────────────────────
resource "kubernetes_resource_quota" "staging" {
  metadata {
    name      = "staging-quota"
    namespace = kubernetes_namespace.staging.metadata[0].name
    labels = {
      "managed-by" = "terraform"
    }
  }

  spec {
    hard = {
      "requests.cpu"    = "500m"
      "requests.memory" = "512Mi"
      "limits.cpu"      = "1000m"
      "limits.memory"   = "1Gi"
      "pods"            = "5"
    }
  }
}

# ──────────────────────────────────────────────────────────────
# Outputs — consumed by Ansible inventory
# ──────────────────────────────────────────────────────────────
output "staging_namespace" {
  value = kubernetes_namespace.staging.metadata[0].name
}

output "staging_deployer_sa" {
  value = kubernetes_service_account.staging_deployer.metadata[0].name
}
