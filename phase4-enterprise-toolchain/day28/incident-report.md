# Day 28 — Incident Simulation: OKD Node Disk Pressure Cascade

## Incident Summary

| Field | Value |
|-------|-------|
| **Date** | 2026-03-03 |
| **Severity** | P1 — Cluster Unavailable |
| **Duration** | ~45 minutes |
| **Root Cause** | CRC VM disk exhaustion caused by container image accumulation + marketplace operator continuous image re-pull |
| **Impact** | OKD API server unavailable, all workloads evicted |
| **Resolution** | CRC VM restarted after disk freed by removing community-operators CatalogSource |

---

## Timeline

```
17:28  Terraform (Day 26): aspnetapp-staging namespace provisioned [+4MB to disk]
17:28  Ansible (Day 26): ConfigMap applied to aspnetapp-staging [no disk change]

17:34  ALERT: DiskPressure: True on node 'crc'
       kubelet sets taint: node.kubernetes.io/disk-pressure:NoSchedule
       Disk: 26.97GB / 32.68GB (82.5%)
       CRC metric: 25.3GB / 32.68GB used (inside CRC VM)

17:35  Investigation begins
       oc get node crc → DiskPressure: True

17:38  Root cause identified
       community-operator-index:v4.20 = 1.27GB
       Marketplace operator pulls this image every ~30 minutes
       Each pull cycle re-fills disk after manual pruning

17:40  Attempted fix: scale Prometheus → 0, prune images
       crictl rmi --prune → deleted scos-content images (~500MB freed)
       DiskPressure still True (82.5% → 82.5%, marketplace re-pulled)

17:42  Attempted fix: oc adm taint node crc disk-pressure:NoSchedule-
       Taint removed manually
       Prometheus pod scheduled → pulled image (407MB) → disk increases
       Kubelet re-applies taint: disk now at 83%
       Grafana: 1/1 Running ✅ (image already in cache)

17:43  Grafana running, Prometheus evicted
       Pod events: Warning Evicted — The node had condition: [DiskPressure]

17:45  Root cause fix: deleted community-operators CatalogSource
       oc delete catalogsource community-operators -n openshift-marketplace
       community-operator-index:v4.20 removed (1.27GB freed)

17:46  Disk freed but marketplace operator re-pulled catalog index
       Disk usage unchanged: 26.97GB (marketplace pulled fresh copy)

17:50  Prometheus pod storm
       Eviction loop: pod created → evicted → new pod → evicted
       65+ pods created and evicted in ~10 minutes
       Deployment controller kept retrying to maintain 1 replica

17:55  Escalation: OKD API server becomes unavailable
       crc status: "CRC VM: Stopped"
       Cause: disk I/O saturation from pod storm + eviction cascade
       API server (etcd write-ahead log) failed under disk pressure

18:00  Recovery initiated: crc start
```

---

## Detection

### Signal 1: Application deployment failure

```bash
oc get pods -n monitoring
# NAME                          READY   STATUS    RESTARTS
# grafana-58cf85f6bd-s88tr      1/1     Running
# prometheus-55496946b9-z5tbb   0/1     Pending   ← deployment blocked
```

### Signal 2: Node conditions

```bash
oc get node crc
# NAME   STATUS                        ROLES    AGE
# crc    Ready,SchedulingDisabled      master   3h
#                         ↑ SchedulingDisabled = DiskPressure taint active

oc describe node crc | grep -A2 DiskPressure
# Type:               DiskPressure
# Status:             True
# Message:            kubelet has disk pressure
```

### Signal 3: Eviction events

```bash
oc get events -n monitoring --sort-by=.lastTimestamp
# Warning  Evicted  pod/prometheus-68bc75455d-djdcs
#   Message: The node had condition: [DiskPressure].
# Warning  FailedScheduling  pod/prometheus-584b8f8474-z5chw
#   Message: 0/1 nodes: disk-pressure taint
```

---

## Diagnosis

### Step 1: Identify disk usage

```bash
# From inside CRC VM via SSH
df -h /var
# Filesystem      Size  Used Avail Use%
# /dev/vda4        31G   25G  5.9G  81%

# Container image usage
crictl images | sort -k4 -hr
# registry.access.redhat.com/redhat/community-operator-index:v4.20  1.27GB
# docker.io/sonatype/nexus3:3.76.0                                   646MB
# docker.io/hashicorp/vault:1.18.3                                   486MB
# quay.io/argoproj/argocd:v2.13.0                                    483MB
# ...
```

### Step 2: Identify the culprit image

```bash
oc get pods -n openshift-marketplace
# community-operators-XXXXX  0/1  Completed  ← uses community-operator-index

oc get catalogsource -n openshift-marketplace
# community-operators  Community Operators  grpc  Red Hat
# ↑ This CatalogSource triggers periodic re-pulls of 1.27GB catalog index
```

### Step 3: Trace the cascade

```
Disk fills (marketplace re-pull) →
  kubelet detects > threshold →
    DiskPressure: True →
      taint set →
        new pods blocked →
          deployment controller creates new pods (with toleration) →
            pods admitted but immediately evicted →
              65+ eviction events →
                massive disk I/O (overlay fs cleanup) →
                  etcd write stalls →
                    API server timeout →
                      CRC VM unresponsive →
                        VM stopped
```

---

## Resolution Steps

### Immediate: Stop the cascade

```bash
# Scale down actively-evicting deployment
oc scale deployment prometheus -n monitoring --replicas=0

# Force delete all pending/evicted pods
oc delete pods -n monitoring -l app=prometheus --grace-period=0 --force
```

### Fix: Remove the continuous image re-puller

```bash
# This stops the marketplace from re-pulling the 1.27GB catalog index
oc delete catalogsource community-operators -n openshift-marketplace
```

### Fix: Prune unused images

```bash
# Inside CRC VM
crictl rmi --prune

# Specific large unused images
crictl rm -f <container-id-using-image>
crictl rmi registry.access.redhat.com/redhat/community-operator-index:v4.20
```

### Recovery: Restart cluster if VM crashed

```bash
crc start
oc login -u kubeadmin -p WD2J7-fZZr9-XFXIn-qxDvg https://api.crc.testing:6443 --insecure-skip-tls-verify
```

---

## Post-Mortem: 5 Whys

1. **Why did the cluster crash?**
   The CRC VM stopped because etcd I/O stalled under extreme disk pressure.

2. **Why was disk pressure so extreme?**
   A pod eviction loop (65+ pods/minute) generated massive container overlay FS I/O.

3. **Why did the eviction loop start?**
   Adding `disk-pressure` toleration to Prometheus allowed pods to be admitted but they were immediately evicted, causing a rapid create-evict cycle.

4. **Why was disk pressure active?**
   The marketplace operator continuously re-pulled a 1.27GB community-operator-index image, consuming disk faster than GC could reclaim.

5. **Why wasn't disk pressure detected earlier?**
   No monitoring alert was configured. Prometheus was being deployed to provide monitoring, but it couldn't start precisely because of the disk pressure it was meant to detect.

> **Classic bootstrap problem**: The monitoring system can't start because of the condition it's supposed to monitor.

---

## Prevention

### 1. Set DiskPressure alert BEFORE deploying new workloads

In production OKD (with cluster monitoring):
```yaml
# PrometheusRule for disk pressure warning
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: disk-pressure-alert
spec:
  groups:
    - name: node-disk
      rules:
        - alert: NodeDiskPressureWarning
          expr: node_filesystem_avail_bytes{mountpoint="/var"} / node_filesystem_size_bytes{mountpoint="/var"} < 0.25
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Node disk approaching eviction threshold (75% used)"
```

### 2. Limit marketplace operator catalog updates

```bash
# Option A: Disable community-operators CatalogSource (already done)
oc delete catalogsource community-operators -n openshift-marketplace

# Option B: Set updateStrategy to avoid re-pulls
oc patch catalogsource community-operators -n openshift-marketplace \
  --type=merge -p '{"spec":{"updateStrategy":{"registryPoll":{"interval":"24h"}}}}'
```

### 3. Never add disk-pressure toleration to Deployments

Tolerating `disk-pressure` taint while the node is under active eviction creates
a feedback loop: pods are admitted but immediately evicted, causing I/O churn.

**Correct approach**: Fix the disk pressure first, then scale up workloads.

### 4. Set ResourceQuotas on CRC cluster

```yaml
# Limit how many images can be cached by capping PVC sizes
# Add cluster-wide ResourceQuota for storage
```

### 5. Use OKD's built-in monitoring for production

OKD includes a pre-configured Prometheus stack (`openshift-monitoring`) with:
- Automatic disk pressure alerting
- Node-level metrics without manual deployment
- PagerDuty/email integrations

```bash
oc get pods -n openshift-monitoring
# prometheus-k8s-0    3/3 Running  ← built-in Prometheus
# alertmanager-main-0 3/3 Running  ← built-in Alertmanager
# grafana-XXXXX       1/1 Running  ← built-in Grafana
```

---

## Lessons for Enterprise

| Lesson | Application |
|--------|------------|
| Monitoring bootstrapping order | Deploy alerting FIRST, then new workloads |
| Image GC strategy | Don't add image-heavy services without disk audit |
| Toleration anti-patterns | Never tolerate pressure taints during active eviction |
| Recovery playbook | Always have `crc start` / `cluster restart` in the runbook |
| CatalogSource management | Disable or limit update frequency for large catalog images |

---

## Cluster Recovery Status

After `crc start`:

```
CRC VM:  Running
OKD:     Running (v4.20.0-okd-scos.11)
Disk:    26.97GB of 54.16GB (50%) — CRC restart freed significant disk space

Surviving workloads (state persisted on PVCs):
- argocd:        ✅ Running
- vault:         ✅ Running
- nexus:         ✅ Running
- aspnetapp-dev: ✅ Running (1/1 replica)
- grafana:       ✅ Running
- prometheus:    ✅ Running (1/1 replica — now works, disk pressure cleared)
```

**Prometheus active scrape jobs after recovery:**
```
Active scrape jobs: ['aspnetapp', 'kubernetes-pods', 'prometheus']
```

The aspnetapp application survived the incident because:
1. It has a PVC for data (not affected by image GC)
2. GitOps (Argo CD) auto-healed the deployment after restart

**Key finding:** The CRC VM disk expanded from 32.68GB to 54.16GB after restart
(CRC appears to have dynamically resized the CRC VM's disk partition on restart).
With 50% disk usage, DiskPressure: False and Prometheus started cleanly.
