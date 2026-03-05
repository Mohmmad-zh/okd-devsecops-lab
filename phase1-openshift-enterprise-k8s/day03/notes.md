# Day 3 — Security Hardening: NetworkPolicy, ResourceQuota, LimitRange

## What We Did

Applied three namespace-level security controls to `dotnet-demo`, layered on top of
the pod-level hardening from Day 2.

## Files

| File | Purpose |
|------|---------|
| `networkpolicy.yaml` | 3 policies: default-deny-all, allow router ingress, allow DNS egress |
| `resourcequota.yaml` | Namespace-level hard caps on compute and object counts |
| `limitrange.yaml` | Default + max limits applied to containers that omit them |
| `deploy.sh` | One-shot apply script |

---

## 1. NetworkPolicy

NetworkPolicy is a Kubernetes-native L3/L4 firewall applied per-namespace.
OpenShift's SDN (OVN-Kubernetes in OKD 4.x) enforces it.

### Strategy: default-deny, then explicit allow

```
default-deny-all       →  block ALL ingress + egress for every pod
allow-from-ingress     →  re-open ingress from OpenShift router only
allow-egress-dns       →  re-open egress to DNS (port 53) only
```

### Key manifests

```yaml
# Block everything
podSelector: {}        # empty = matches ALL pods in namespace
policyTypes: [Ingress, Egress]

# Allow router ingress (OpenShift-specific label)
namespaceSelector:
  matchLabels:
    network.openshift.io/policy-group: ingress

# Allow DNS egress
egress:
  - ports:
    - port: 53 / UDP
    - port: 53 / TCP
```

### Verified: Route still returns HTTP 200 after applying default-deny

This works because the router namespace carries the `network.openshift.io/policy-group: ingress`
label, so it's explicitly permitted. All other ingress (e.g. direct pod-to-pod) is dropped.

---

## 2. ResourceQuota

ResourceQuota enforces hard caps at the **namespace level** — across all pods combined.

```yaml
requests.cpu:    500m    # total CPU requested by all pods
limits.cpu:      2       # total CPU limit across all pods
requests.memory: 256Mi
limits.memory:   1Gi
pods:            10      # max pod count
services:        5
secrets:         20
configmaps:      10
persistentvolumeclaims: 5
count/routes.route.openshift.io: 5
```

### Verified: quota blocks oversized pod

```
Error: pods "quota-test" is forbidden:
  maximum cpu usage per Container is 500m, but limit is 4
  maximum cpu usage per Pod is 1, but limit is 4
```

### Live quota usage after Day 2 app

```
limits.cpu      500m / 2      (aspnetapp uses its full 500m limit)
limits.memory   256Mi / 1Gi
requests.cpu    100m / 500m
requests.memory 128Mi / 256Mi
pods            1 / 10
```

---

## 3. LimitRange

LimitRange operates at the **container level** within a namespace.
It does two things:
1. Injects **default** requests/limits into containers that don't specify them
2. Enforces **min/max** bounds — admission rejects anything outside the range

```yaml
# Container defaults (injected if omitted)
defaultRequest: { cpu: 50m,  memory: 64Mi  }
default:        { cpu: 200m, memory: 128Mi }

# Hard bounds
min: { cpu: 10m,  memory: 16Mi  }
max: { cpu: 500m, memory: 256Mi }

# Pod-level ceiling
Pod max: { cpu: 1, memory: 512Mi }
```

### Verified: LimitRange blocks container exceeding max

```
Error: pods "limitrange-test" is forbidden:
  maximum memory usage per Container is 256Mi, but limit is 1Gi
  maximum memory usage per Pod is 512Mi, but limit is 1Gi
```

---

## Security Layers Now Active on dotnet-demo

| Layer | Control | What it does |
|-------|---------|-------------|
| Pod (Day 2) | `runAsNonRoot: true` | Container fails if image runs as root |
| Pod (Day 2) | `allowPrivilegeEscalation: false` | No sudo/setuid escalation |
| Pod (Day 2) | `capabilities: drop: ALL` | No Linux capabilities |
| Pod (Day 2) | `seccompProfile: RuntimeDefault` | Syscall filter |
| Namespace (Day 3) | NetworkPolicy default-deny | No traffic in or out unless explicitly allowed |
| Namespace (Day 3) | ResourceQuota | Prevents resource exhaustion of the node |
| Namespace (Day 3) | LimitRange | Ensures every container has limits; caps runaway containers |

---

## Concepts

- **NetworkPolicy** — L3/L4 firewall; needs a CNI plugin that enforces it (OVN-K in OKD 4.x does)
- **ResourceQuota** — namespace budget; prevents one team from starving others on a shared cluster
- **LimitRange** — per-container guardrails; prevents unbounded containers that have no limits set
- **Defense in depth** — each layer catches different attack/failure modes; none alone is sufficient

## Commands

```bash
# View current quota usage
oc describe resourcequota dotnet-demo-quota -n dotnet-demo

# View limitrange
oc describe limitrange dotnet-demo-limits -n dotnet-demo

# List network policies
oc get networkpolicy -n dotnet-demo

# Describe a specific policy
oc describe networkpolicy default-deny-all -n dotnet-demo
```
