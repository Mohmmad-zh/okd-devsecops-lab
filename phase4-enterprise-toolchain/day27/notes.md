# Day 27 — Monitoring (Prometheus + Grafana)

## Goals
- Deploy Prometheus in the monitoring namespace (RBAC + ConfigMap from Day 24 Terraform)
- Deploy Grafana with Prometheus datasource auto-provisioned
- Expose both via OKD Routes
- Verify Grafana can connect to Prometheus

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    monitoring namespace                          │
│                                                                  │
│  ┌─────────────────┐         ┌──────────────────────────────┐  │
│  │   Prometheus    │         │         Grafana              │  │
│  │  :9090          │◄────────│  datasource: http://prometheus│  │
│  │  ConfigMap:     │         │  admin: grafana-admin-2024!  │  │
│  │  prometheus.yml │         │  Dashboard: aspnetapp-dev    │  │
│  │  PVC: 5Gi TSDB  │         │  :3000                       │  │
│  └────────┬────────┘         └──────────────┬───────────────┘  │
│           │ Route                           │ Route             │
└───────────┼─────────────────────────────────┼──────────────────┘
            │                                 │
  https://prometheus-monitoring.apps-crc.testing
                                    https://grafana-monitoring.apps-crc.testing
```

---

## Terraform Foundation (Day 24)

The monitoring namespace already had these resources from Day 24 Terraform:

| Resource | Name | Purpose |
|----------|------|---------|
| Namespace | monitoring | Boundary (managed-by: terraform) |
| ServiceAccount | prometheus-sa | Pod identity for scraping |
| ClusterRole | prometheus-scraper | read nodes/pods/services cluster-wide |
| ClusterRoleBinding | prometheus-scraper-binding | Binds SA to ClusterRole |
| ConfigMap | prometheus-config | Full prometheus.yml with scrape jobs |
| PVC | prometheus-storage | 5Gi for TSDB data |

---

## Day 27 Deployments

### Prometheus

```yaml
spec:
  serviceAccountName: prometheus-sa
  securityContext:
    runAsUser: 65534   # nobody
    fsGroup: 65534
  containers:
    - image: quay.io/prometheus/prometheus:v2.47.0
      resources:
        requests: { cpu: 50m, memory: 128Mi }
        limits:   { cpu: 500m, memory: 512Mi }
```

SCC fix required:
```bash
oc adm policy add-scc-to-user anyuid -z prometheus-sa -n monitoring
```

OKD assigns UIDs in the range [1000780000, 1000789999] by default. Since Prometheus runs as UID 65534, anyuid SCC was needed.

### Grafana

```yaml
spec:
  serviceAccountName: grafana-sa
  containers:
    - image: docker.io/grafana/grafana:10.2.0
      env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "grafana-admin-2024!"
      resources:
        requests: { cpu: 25m, memory: 64Mi }
        limits:   { cpu: 250m, memory: 256Mi }
```

Datasource auto-provisioned via ConfigMap:
```yaml
data:
  datasources.yaml: |
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://prometheus.monitoring.svc.cluster.local:9090
        isDefault: true
```

---

## Results

### Final results (after disk expansion — Day 28 resolution):

| Component | Status | Notes |
|-----------|--------|-------|
| Prometheus | 1/1 Running ✅ | `https://prometheus-monitoring.apps-crc.testing` |
| Grafana | 1/1 Running ✅ | `https://grafana-monitoring.apps-crc.testing` |
| Prometheus Route | Created ✅ | Edge TLS, no auth |
| Grafana Route | Created ✅ | Edge TLS, admin/grafana-admin-2024! |
| Grafana Datasource | Configured ✅ | Prometheus auto-provisioned via ConfigMap |
| Grafana Dashboard | Created ✅ | "OKD Monitoring — aspnetapp-dev" |
| Prometheus scraping | Active ✅ | 4/8 targets up (prometheus + 3 kubernetes-pods) |

### Active Prometheus targets:

```
prometheus                             UP   (self-monitoring)
kubernetes-pods (node-exporter x3)    UP   (CRC system pods)
aspnetapp                              DOWN (sample app has no /metrics endpoint)
kubernetes-pods (others)               DOWN (no prometheus.io/scrape annotation)
```

The `aspnetapp` target is down by design — the `mcr.microsoft.com/dotnet/samples:aspnetapp`
image does not expose `/metrics`. In production, add `prometheus-net` middleware to the ASP.NET app.

### Lab constraint encountered (resolved by Day 28):

During initial deployment, Prometheus could not run due to disk pressure:
- CRC VM `/dev/vda4`: 31GB total, ~85% used → DiskPressure: True
- Pod eviction storm: Prometheus created → evicted → created → evicted

**Resolution:** Expanded CRC QCOW2 image from 31GB to 51GB via:
```bash
crc stop
sudo qemu-img resize /home/ubuntu/.crc/machines/crc/crc.qcow2 +20G
crc start   # CRC auto-ran: "Resizing /dev/vda4 filesystem"
```
After restart: disk at 51%, DiskPressure: False, Prometheus: 1/1 Running.

---

## Prometheus Configuration (from Day 24 Terraform)

The prometheus.yml ConfigMap configures:

```yaml
scrape_configs:
  # Prometheus self-monitoring
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  # Kubernetes API server
  - job_name: kubernetes-apiservers
    kubernetes_sd_configs:
      - role: endpoints
    scheme: https
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token

  # All pods with prometheus.io/scrape=true annotation
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"

  # aspnetapp direct scrape
  - job_name: aspnetapp
    static_configs:
      - targets: ['aspnetapp.aspnetapp-dev.svc.cluster.local:8080']
```

---

## Grafana Dashboard

An aspnetapp dashboard was configured with:
- HTTP Requests Total (stat panel)
- Pod CPU usage (timeseries)
- Pod Memory usage (timeseries)
- Available Replicas (stat panel)

In production (with Prometheus running), these panels would show live metrics from the aspnetapp deployment.

---

## Credentials

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | https://grafana-monitoring.apps-crc.testing | admin / grafana-admin-2024! |
| Prometheus | https://prometheus-monitoring.apps-crc.testing | (no auth) |

---

## Key Takeaway

**Lab constraint vs Production**: A CRC single-node cluster (32GB disk, 16GB RAM) cannot sustain
a full enterprise toolchain stack (Nexus + Vault + Argo CD + Prometheus + Grafana + aspnetapp).
In production:
- Use dedicated namespace VMs or cloud nodes for each service tier
- Prometheus should run on a monitoring-dedicated node
- OKD 4.x includes an integrated monitoring stack (`cluster-monitoring-config`) for production use

The monitoring configuration (prometheus.yml, Grafana datasource, RBAC) is production-correct.
Only the compute/disk resources are the lab constraint.
