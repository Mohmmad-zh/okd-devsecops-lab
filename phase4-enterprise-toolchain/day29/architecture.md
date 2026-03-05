# Day 29 — Enterprise Architecture Diagram

## Full 30-Day Lab Architecture

This document captures the complete enterprise-grade OKD/DevSecOps architecture
built over 30 days.

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        Windows 11 Hyper-V Host                                  │
│                                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                     Ubuntu 22.04 LTS VM (16GB RAM, 80GB disk)           │  │
│  │                                                                          │  │
│  │  ┌──────────────────────────────────────────────────────────────────┐   │  │
│  │  │               OKD 4.20 / CRC 2.58.0 (Single-Node Cluster)        │   │  │
│  │  │                    api.crc.testing:6443                           │   │  │
│  │  │                    *.apps-crc.testing                             │   │  │
│  │  │                                                                   │   │  │
│  │  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────────────┐   │   │  │
│  │  │  │   argocd    │  │    vault     │  │      monitoring       │   │   │  │
│  │  │  │  namespace  │  │  namespace   │  │      namespace        │   │   │  │
│  │  │  │             │  │              │  │                       │   │   │  │
│  │  │  │ argo-cd     │  │  hashicorp   │  │  prometheus:9090      │   │   │  │
│  │  │  │ server      │  │  vault:8200  │  │  grafana:3000         │   │   │  │
│  │  │  │ repo-server │  │  KV engine   │  │  scrapes all pods     │   │   │  │
│  │  │  │ app-ctrl    │  │  K8s auth    │  │                       │   │   │  │
│  │  │  └──────┬──────┘  └──────┬───────┘  └───────────────────────┘   │   │  │
│  │  │         │ sync            │ secrets                                │   │  │
│  │  │  ┌──────▼──────┐  ┌──────▼───────┐  ┌───────────────────────┐   │   │  │
│  │  │  │ aspnetapp   │  │  devsecops   │  │       nexus           │   │   │  │
│  │  │  │   -dev      │  │  namespace   │  │      namespace        │   │   │  │
│  │  │  │   -test     │  │              │  │                       │   │   │  │
│  │  │  │   -prod     │  │ semgrep SAST │  │ docker-hosted:8082    │   │   │  │
│  │  │  │  -staging   │  │ trivy scans  │  │ docker-proxy:8083     │   │   │  │
│  │  │  │             │  │              │  │ nuget-group:8081      │   │   │  │
│  │  │  └─────────────┘  └──────────────┘  └───────────────────────┘   │   │  │
│  │  └──────────────────────────────────────────────────────────────────┘   │  │
│  │                                                                          │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐    │  │
│  │  │                        Toolchain (Host OS)                      │    │  │
│  │  │  terraform v1.14.6  │  ansible 2.10.8  │  vault cli v1.18.3    │    │  │
│  │  │  skopeo 1.4.1       │  trivy 0.69.3    │  semgrep              │    │  │
│  │  │  argocd cli v2.13.0 │  oc cli 4.20.0   │                       │    │  │
│  │  └─────────────────────────────────────────────────────────────────┘    │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## CI/CD Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Developer Workflow                                 │
│                                                                             │
│  1. Developer commits code                                                  │
│         │                                                                   │
│         ▼                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                       Security Gate                                  │   │
│  │                                                                     │   │
│  │  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────┐  │   │
│  │  │   Semgrep SAST   │    │  Trivy Container │    │ dotnet SCA   │  │   │
│  │  │  Custom C# rules │    │  Scan (CRITICAL) │    │ SBOM CycloneDX│  │   │
│  │  │  PASS → proceed  │    │  0 CVEs → pass   │    │              │  │   │
│  │  │  FAIL → block    │    │  >0 → block      │    │              │  │   │
│  │  └────────┬─────────┘    └────────┬─────────┘    └──────┬───────┘  │   │
│  │           │ PASS                  │ PASS                 │ PASS      │   │
│  └───────────┼───────────────────────┼──────────────────────┼──────────┘   │
│              └──────────────┬────────┘                      │              │
│                             ▼                               │              │
│  2. Build image tagged with GIT_SHA (a3f8b2c)               │              │
│         │                                                               │  │
│         ▼                                                               │  │
│  3. skopeo copy → Nexus docker-hosted                                   │  │
│          OR → OpenShift internal registry (cert-trusted)                │  │
│         │                                                               │  │
│         ▼                                                               │  │
│  4. Update GitOps manifest                                              │  │
│     image: image-registry.svc:5000/aspnetapp-dev/aspnetapp:a3f8b2c     │  │
│         │                                                               │  │
│         ▼                                                               │  │
│  5. git push → Gitea (gitea.apps-crc.testing)                          │  │
│         │                                                               │  │
│         ▼                                                               │  │
│  6. Argo CD detects change (polling / webhook)                          │  │
│     auto-sync: aspnetapp-dev → deploy new pod                          │  │
│         │                                                               │  │
│         ▼                                                               │  │
│  7. Promotion pipeline (dev → test → prod)                             │  │
│     Manual approval gate at test→prod boundary                         │  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Security Architecture (Defense-in-Depth)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Security Layers                                      │
│                                                                             │
│  Layer 1: Code Security                                                     │
│  ├── Semgrep SAST: C# custom rules (SQL injection, hardcoded secrets)      │
│  ├── dotnet SCA: dependency vulnerability scanning                         │
│  └── SBOM: CycloneDX inventory for audit trail                             │
│                                                                             │
│  Layer 2: Container Security                                                │
│  ├── Trivy: image scanning (block on CRITICAL CVEs)                        │
│  ├── OKD SCC: restricted Security Context Constraints (non-root)           │
│  ├── securityContext: runAsNonRoot, readOnlyRootFilesystem                 │
│  └── Immutable image tags: SHA-based (a3f8b2c, not :latest)               │
│                                                                             │
│  Layer 3: Cluster Security                                                  │
│  ├── RBAC: custom Role + RoleBinding (least privilege)                     │
│  ├── NetworkPolicy: namespace isolation                                     │
│  ├── ResourceQuota: CPU/memory caps per namespace                          │
│  └── LimitRange: container-level default limits                            │
│                                                                             │
│  Layer 4: Secret Management                                                 │
│  ├── HashiCorp Vault: KV secrets engine (version 2)                       │
│  ├── Vault K8s Auth: pod identity-based secret access                     │
│  ├── AppRole: CI/CD pipeline credential rotation                           │
│  └── Dynamic secrets: no long-lived credentials in code                   │
│                                                                             │
│  Layer 5: GitOps Governance                                                 │
│  ├── Argo CD AppProject: restricts source repos and destination namespaces │
│  ├── Sync windows: production changes only during business hours           │
│  ├── Self-healing: drift auto-corrected within 3 minutes                   │
│  └── Rollback: git revert = instant production rollback                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Infrastructure-as-Code Layer

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      IaC / Configuration Management                         │
│                                                                             │
│  Terraform (HashiCorp)                 Ansible (Red Hat)                   │
│  ─────────────────────                 ─────────────────────               │
│  Provider: kubernetes v2.35            Inventory: localhost (local conn)   │
│                                                                             │
│  Managed resources:                    Managed tasks:                      │
│  ├── Namespace: monitoring             ├── Tool verification               │
│  │   Labels: managed-by=terraform      │   (Trivy, Vault, ArgoCD, oc)     │
│  ├── ServiceAccount: prometheus-sa     ├── Idempotent package install      │
│  ├── ClusterRole: prometheus-scraper   ├── ConfigMap application          │
│  ├── ClusterRoleBinding                └── Cluster health checks          │
│  ├── ConfigMap: prometheus-config                                          │
│  ├── PVC: prometheus-storage (5Gi)     Combined pipeline (Day 26):        │
│  ├── Namespace: aspnetapp-staging      terraform apply →                  │
│  ├── ServiceAccount: staging-deployer  ansible-playbook configure_staging  │
│  ├── Role: staging-deployer                                                │
│  ├── RoleBinding                       Tool separation:                   │
│  └── ResourceQuota: staging-quota      Terraform = infrastructure         │
│                                        Ansible = configuration            │
│  State: local terraform.tfstate                                            │
│  Drift detection: terraform plan       Both: idempotent, declarative      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Monitoring Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Monitoring Stack                                   │
│                                                                             │
│  Prometheus (quay.io/prometheus/prometheus:v2.47.0)                        │
│  ├── ServiceAccount: prometheus-sa (anyuid SCC)                            │
│  ├── ClusterRole: read nodes/pods/services/endpoints across all namespaces  │
│  ├── Storage: 5Gi PVC (prometheus-storage)                                 │
│  ├── Retention: 7 days TSDB                                                │
│  └── Scrape jobs:                                                          │
│      ├── prometheus (self: localhost:9090)                                  │
│      ├── kubernetes-apiservers (https, bearer token auth)                  │
│      ├── kubernetes-pods (annotation-based: prometheus.io/scrape=true)    │
│      └── aspnetapp (static: aspnetapp.aspnetapp-dev.svc:8080)             │
│                                                                             │
│  Grafana (docker.io/grafana/grafana:10.2.0)                               │
│  ├── Datasource: Prometheus (auto-provisioned ConfigMap)                   │
│  ├── Dashboard: aspnetapp-dev (CPU, Memory, Replicas, HTTP)               │
│  ├── Admin: grafana-admin-2024!                                            │
│  └── Route: https://grafana-monitoring.apps-crc.testing                   │
│                                                                             │
│  Production alternative: OpenShift Monitoring Stack                        │
│  └── openshift-monitoring namespace (pre-installed in OKD)                │
│      ├── prometheus-k8s-0 (3/3 Running)                                   │
│      ├── alertmanager-main-0 (3/3 Running)                                │
│      └── Thanos for long-term storage                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Namespace Map

| Namespace | Purpose | Key Resources |
|-----------|---------|--------------|
| `aspnetapp-dev` | Dev environment | Deployment, Service, Route, HPA |
| `aspnetapp-test` | Test environment | Kustomize overlay |
| `aspnetapp-prod` | Production | Kustomize overlay + sync window |
| `aspnetapp-staging` | Staging (Day 26) | TF: Namespace, RBAC, Quota / Ansible: ConfigMap |
| `argocd` | GitOps controller | AppProject, Applications |
| `vault` | Secrets management | Vault pod, KV engine, K8s auth |
| `monitoring` | Observability | Prometheus, Grafana, Routes |
| `nexus` | Artifact registry | Nexus OSS, Docker repos, NuGet repos |
| `devsecops` | Security tooling | Semgrep, Trivy scan jobs |
| `cert-manager` | TLS automation | Issuers, Certificates |

---

## Technology Stack Summary

| Layer | Technology | Version | Purpose |
|-------|-----------|---------|---------|
| **Platform** | OKD (Community OpenShift) | 4.20.0 | Kubernetes cluster |
| **Runtime** | CRC (OpenShift Local) | 2.58.0 | Single-node dev cluster |
| **GitOps** | Argo CD | v2.13.0 | Continuous deployment |
| **Secret Mgmt** | HashiCorp Vault | v1.18.3 | Secret injection |
| **Artifact Reg** | Sonatype Nexus OSS | 3.76.0 | Docker + NuGet repos |
| **Monitoring** | Prometheus | v2.47.0 | Metrics collection |
| **Dashboarding** | Grafana | 10.2.0 | Visualization |
| **SAST** | Semgrep | latest | Static analysis |
| **Container Scan** | Trivy | 0.69.3 | CVE scanning |
| **Image Copy** | Skopeo | 1.4.1 | Daemonless image ops |
| **IaC** | Terraform | v1.14.6 | K8s resource provisioning |
| **Config Mgmt** | Ansible | 2.10.8 | Configuration automation |
| **App** | ASP.NET 8 | latest | Sample application |
| **Registry** | OpenShift Internal | built-in | Production image store |

---

## Production vs Lab Gaps

| Concern | Lab (CRC) | Production |
|---------|-----------|------------|
| Cluster nodes | 1 (all roles) | 3+ control plane + N workers |
| Disk per node | 32-54GB | 500GB+ SSD |
| Registry TLS | Self-signed (OKD wildcard) | cert-manager + Let's Encrypt |
| Terraform state | Local file | S3/GCS/Azure backend + DynamoDB lock |
| Nexus storage | 10Gi PVC | External NAS or S3-compatible |
| Vault storage | In-memory dev mode | HA Raft cluster + unsealing |
| Monitoring | Self-hosted Prometheus | OKD cluster-monitoring + Thanos |
| GitOps source | Gitea (on-cluster) | GitHub/GitLab (external) |
| Pipeline | Manual shell scripts | Azure DevOps / GitHub Actions |

---

## Key Architectural Patterns

### 1. GitOps: Single Source of Truth

```
Git repo (Gitea) → Argo CD watches → OKD cluster state
      ↑                                        │
      └────────── CI/CD promotes image ◄───────┘
                  (git commit is the deploy)
```

### 2. Immutable Infrastructure

- Container images tagged with GIT_SHA (not :latest)
- Nexus `writePolicy: allow_once` prevents tag overwrite
- Deployment = git commit → audit trail = git log

### 3. Shift-Left Security

```
Code → [Semgrep] → [Trivy] → [dotnet SCA] → Build → Deploy
         SAST       Image      Dependencies
                   Scan
       Block early — cheaper to fix in development
```

### 4. Secret Rotation without Code Changes

```
Vault → Kubernetes Secret (injected at pod start)
     → AppRole token (rotated by CI/CD)
     → Dynamic secrets (expired automatically)
     App code never touches secrets directly
```
