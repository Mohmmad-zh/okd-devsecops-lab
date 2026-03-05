# Security Posture — dotnet-demo Namespace

## Defence-in-Depth Model

Security is applied at four distinct layers. Each layer catches failures and
attacks that the others cannot.

```
┌─────────────────────────────────────────────────────────────────┐
│  LAYER 4 — RBAC                                                 │
│  Least-privilege identity; no token mount; no cluster access    │
├─────────────────────────────────────────────────────────────────┤
│  LAYER 3 — NAMESPACE CONTROLS                                   │
│  NetworkPolicy · ResourceQuota · LimitRange                     │
├─────────────────────────────────────────────────────────────────┤
│  LAYER 2 — POD / CONTAINER SECURITY                             │
│  SCC · SecurityContext · probes · resource limits               │
├─────────────────────────────────────────────────────────────────┤
│  LAYER 1 — PLATFORM                                             │
│  OpenShift SCC admission · OLM · OVN-Kubernetes CNI             │
└─────────────────────────────────────────────────────────────────┘
```

---

## Layer 1 — Platform Controls

| Control | Value | What it prevents |
|---------|-------|-----------------|
| SCC admission webhook | Rejects pods violating `restricted-v2` | No root containers, no privilege escalation, no host paths |
| OVN-Kubernetes CNI | Enforces NetworkPolicy | East-west traffic between namespaces is blocked by default |
| OLM | Manages operator lifecycle | Operators installed via verified channels, not manual YAML |

---

## Layer 2 — Pod / Container Security

Applied in [day02/deployment.yaml](../day02/deployment.yaml):

| Field | Setting | Effect |
|-------|---------|--------|
| `runAsNonRoot: true` | `true` | Admission rejects image if it runs as UID 0 |
| `runAsUser` | Not set (OpenShift allocates) | UID `1000660000` assigned from namespace range |
| `allowPrivilegeEscalation` | `false` | `setuid`/`setgid` binaries and `sudo` cannot gain privileges |
| `capabilities.drop` | `ALL` | No Linux capabilities — cannot bind port < 1024, no raw sockets, etc. |
| `seccompProfile` | `RuntimeDefault` | ~300 syscalls allowed; everything else returns EPERM |
| `readOnlyRootFilesystem` | Not set (aspnetapp needs `/tmp`) | Trade-off: acceptable for .NET runtime temp files |

### Resource Limits

| Resource | Request | Limit | Enforced by |
|----------|---------|-------|-------------|
| CPU | 100m | 500m | cgroups (throttled if exceeded) |
| Memory | 128Mi | 256Mi | cgroups (OOMKilled if exceeded) |

### Health Probes

| Probe | Path | Initial Delay | Period | Effect |
|-------|------|--------------|--------|--------|
| Liveness | `GET /` :8080 | 15s | 20s | Pod restarted if app hangs |
| Readiness | `GET /` :8080 | 10s | 10s | Pod removed from Service endpoints until healthy |

---

## Layer 3 — Namespace Controls

### NetworkPolicy (zero-trust networking)

```
Default stance: DENY ALL ingress and egress

Explicit allowances:
  INGRESS  ← OpenShift Router namespace only
             (label: network.openshift.io/policy-group=ingress)
  EGRESS   → DNS only (UDP/TCP port 53)

Result:
  ✗ Pod cannot be reached directly from other pods/namespaces
  ✗ Pod cannot initiate connections to the internet or other services
  ✓ Pod can receive traffic from the OpenShift Router (Route)
  ✓ Pod can resolve DNS names
```

### ResourceQuota (namespace budget)

| Resource | Used | Hard Limit |
|----------|------|-----------|
| requests.cpu | 100m | 500m |
| limits.cpu | 500m | 2 |
| requests.memory | 128Mi | 256Mi |
| limits.memory | 256Mi | 1Gi |
| pods | 1 | 10 |
| services | 1 | 5 |
| secrets | 3 | 20 |

Prevents resource starvation of the cluster by a single runaway namespace.

### LimitRange (container guardrails)

| Type | Min CPU | Max CPU | Default CPU req/lim | Min Mem | Max Mem | Default Mem req/lim |
|------|---------|---------|---------------------|---------|---------|---------------------|
| Container | 10m | 500m | 50m / 200m | 16Mi | 256Mi | 64Mi / 128Mi |
| Pod | — | 1 | — | — | 512Mi | — |

Ensures containers that omit limits still get sensible defaults injected.
Blocks containers that request more than the max — admission denied immediately.

---

## Layer 4 — RBAC

### Identity

| Field | Value |
|-------|-------|
| ServiceAccount | `aspnetapp-sa` (dedicated, not `default`) |
| automountServiceAccountToken | `false` (pod AND SA level) |
| Token in pod filesystem | None — cannot call the K8s API |

### Permissions (Role: `aspnetapp-role`)

| Resource | Allowed Verbs | Denied |
|----------|--------------|--------|
| configmaps | get, list, watch | create, update, delete, patch |
| secrets | get | list, create, update, delete |
| pods | get | list, create, delete, exec |
| deployments | — | ALL |
| nodes | — | ALL |
| Any other namespace | — | ALL |

`oc auth can-i` verified: all 4 allowed → `yes`, all 8 denied → `no`.

---

## Attack Scenario Mitigations

### Scenario A: Container escape (RCE in app)

| What attacker can do | Why they're blocked |
|---------------------|-------------------|
| Try to run as root | `runAsNonRoot: true` — process is UID 1000660000 |
| Try to escalate privileges | `allowPrivilegeEscalation: false` |
| Use dangerous syscalls | `seccompProfile: RuntimeDefault` returns EPERM |
| Call the K8s API | No token mounted — 401 Unauthorized |
| Reach other pods/services | NetworkPolicy default-deny — TCP reset |
| Consume all node CPU/RAM | ResourceQuota + LimitRange — cgroups hard cap |

### Scenario B: Misconfigured deployment (bad image/crash)

| Failure | Protection |
|---------|-----------|
| Bad image pushed | `ImagePullBackOff` — old pod stays serving (Rolling update) |
| App crashes on start | Readiness probe blocks traffic, `CrashLoopBackOff` shows up |
| Memory leak | OOMKill at 256Mi — pod restarted, other pods unaffected |
| CPU spike | Throttled at 500m — no impact on other pods |
| Runaway pod spawning | ResourceQuota: max 10 pods, ReplicaSet prevents extras |

---

## What's NOT Covered Yet

| Gap | Planned Day |
|-----|------------|
| Image vulnerability scanning | Day 16 (Trivy) |
| Secrets management (Vault) | Day 18-19 |
| TLS certificate automation | cert-manager installed Day 5, integrated Day 16+ |
| Pipeline security (SAST, SCA) | Day 15-17 |
| Audit logging | Day 21 |
| Multi-replica for HA | Day 27 |
