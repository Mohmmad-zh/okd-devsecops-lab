terraform {
  required_version = ">= 1.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }

  # Local state for lab — in production use an S3/GCS/Azure backend
  backend "local" {
    path = "terraform.tfstate"
  }
}

# ──────────────────────────────────────────────────────────────
# Provider: kubernetes — connects to OKD cluster via kubeconfig
# ──────────────────────────────────────────────────────────────
provider "kubernetes" {
  # Uses ~/.kube/config by default
  # oc login sets this automatically
}

# ──────────────────────────────────────────────────────────────
# Monitoring namespace
# ──────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "managed-by"  = "terraform"
      "environment" = "lab"
      "purpose"     = "monitoring"
    }
  }
}

# ──────────────────────────────────────────────────────────────
# ServiceAccount for Prometheus (needs cluster-wide read access)
# ──────────────────────────────────────────────────────────────
resource "kubernetes_service_account" "prometheus" {
  metadata {
    name      = "prometheus-sa"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      "managed-by" = "terraform"
      "app"        = "prometheus"
    }
  }
}

# ──────────────────────────────────────────────────────────────
# ClusterRole: Prometheus needs to scrape pods/services across
# all namespaces
# ──────────────────────────────────────────────────────────────
resource "kubernetes_cluster_role" "prometheus" {
  metadata {
    name = "prometheus-scraper"
    labels = {
      "managed-by" = "terraform"
    }
  }

  rule {
    api_groups = [""]
    resources  = ["nodes", "nodes/proxy", "nodes/metrics", "services", "endpoints", "pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["extensions", "networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    non_resource_urls = ["/metrics", "/metrics/cadvisor"]
    verbs             = ["get"]
  }
}

# ──────────────────────────────────────────────────────────────
# ClusterRoleBinding: Bind Prometheus SA to ClusterRole
# ──────────────────────────────────────────────────────────────
resource "kubernetes_cluster_role_binding" "prometheus" {
  metadata {
    name = "prometheus-scraper-binding"
    labels = {
      "managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.prometheus.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.prometheus.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

# ──────────────────────────────────────────────────────────────
# ConfigMap: Prometheus scrape configuration
# ──────────────────────────────────────────────────────────────
resource "kubernetes_config_map" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      "managed-by" = "terraform"
      "app"        = "prometheus"
    }
  }

  data = {
    "prometheus.yml" = <<-EOT
      global:
        scrape_interval: 15s
        evaluation_interval: 15s

      scrape_configs:
        # Scrape Prometheus itself
        - job_name: prometheus
          static_configs:
            - targets: ['localhost:9090']

        # Scrape Kubernetes API server
        - job_name: kubernetes-apiservers
          kubernetes_sd_configs:
            - role: endpoints
          scheme: https
          tls_config:
            ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
            insecure_skip_verify: true
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          relabel_configs:
            - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
              action: keep
              regex: default;kubernetes;https

        # Scrape all pods with prometheus.io/scrape=true annotation
        - job_name: kubernetes-pods
          kubernetes_sd_configs:
            - role: pod
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: "true"
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
              action: replace
              regex: ([^:]+)(?::\d+)?;(\d+)
              replacement: $1:$2
              target_label: __address__
            - source_labels: [__meta_kubernetes_namespace]
              action: replace
              target_label: kubernetes_namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: kubernetes_pod_name

        # Scrape aspnetapp (our application)
        - job_name: aspnetapp
          static_configs:
            - targets: ['aspnetapp.aspnetapp-dev.svc.cluster.local:8080']
          metrics_path: /metrics
    EOT
  }
}

# ──────────────────────────────────────────────────────────────
# PersistentVolumeClaim: Prometheus TSDB storage
# ──────────────────────────────────────────────────────────────
resource "kubernetes_persistent_volume_claim" "prometheus_storage" {
  metadata {
    name      = "prometheus-storage"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      "managed-by" = "terraform"
      "app"        = "prometheus"
    }
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }

  wait_until_bound = false
}
