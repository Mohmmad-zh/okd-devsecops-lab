# Day 2 — Deploy a Hardened .NET App on OpenShift

## What We Built

Deployed the public `mcr.microsoft.com/dotnet/samples:aspnetapp` image to a `dotnet-demo`
namespace with production-grade security and reliability settings.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | `dotnet-demo` project |
| `deployment.yaml` | Hardened Deployment manifest |
| `service.yaml` | ClusterIP Service on port 8080 |
| `route.yaml` | TLS edge-terminated Route |
| `deploy.sh` | One-shot deploy script |

## Key Hardening Applied

### Security Context
```yaml
securityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```
- `allowPrivilegeEscalation: false` — process can never gain more privileges
- `runAsNonRoot: true` — enforced at admission; container fails to start if image tries to run as root
- `drop: ALL` — removes every Linux capability (NET_BIND_SERVICE, etc.)
- `seccompProfile: RuntimeDefault` — syscall filter via seccomp

### OpenShift SCC Behaviour
**Key lesson:** Do NOT hardcode `runAsUser` / `fsGroup` in OpenShift.
- OpenShift's `restricted-v2` SCC allocates a UID from a per-namespace range (e.g., `1000660000–1000669999`)
- Hardcoding UID `1001` fails SCC validation — `restricted-v2` rejects UIDs outside the allocated range
- Correct approach: set `runAsNonRoot: true` and let OpenShift assign the UID
- Actual UID assigned: **1000660000** (confirmed via `oc get pod -o jsonpath`)
- SCC used: **restricted-v2** (most restrictive, no special grants needed)

### Resource Limits
```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"
```
- Requests: guaranteed scheduler allocation
- Limits: hard ceiling — OOM kill if exceeded for memory; throttled if exceeded for CPU

### Health Probes
```yaml
livenessProbe:      # restarts pod if app locks up
  httpGet: { path: /, port: 8080 }
  initialDelaySeconds: 15
  periodSeconds: 20

readinessProbe:     # removes pod from service until app is ready
  httpGet: { path: /, port: 8080 }
  initialDelaySeconds: 10
  periodSeconds: 10
```

### Route (OpenShift-specific)
```yaml
tls:
  termination: edge           # TLS terminated at the router
  insecureEdgeTerminationPolicy: Redirect   # HTTP → HTTPS redirect
```
- URL: `https://aspnetapp-dotnet-demo.apps-crc.testing`
- OpenShift Router handles TLS; app only speaks plain HTTP internally

## Commands Used

```bash
# Deploy everything
oc apply -f namespace.yaml
oc apply -f deployment.yaml
oc apply -f service.yaml
oc apply -f route.yaml

# Watch rollout
oc rollout status deployment/aspnetapp -n dotnet-demo

# Check what SCC and UID were assigned
oc get pod <name> -n dotnet-demo \
  -o jsonpath='UID={.spec.containers[0].securityContext.runAsUser} SCC={.metadata.annotations.openshift\.io/scc}'

# Get the Route URL
oc get route aspnetapp -n dotnet-demo
```

## Troubleshooting Encountered

| Error | Cause | Fix |
|-------|-------|-----|
| `pods is forbidden: unable to validate against any SCC` | Hardcoded `runAsUser: 1001` rejected by `restricted-v2` (requires range `1000660000+`) | Remove explicit `runAsUser`/`fsGroup` — let OpenShift assign |
| `oc login: unknown flag -q` | OKD 4.20 doesn't support `-q` flag on `oc login` | Removed `-q` flag |

## Concepts Reinforced

- **SCC (SecurityContextConstraint)** — OpenShift's admission controller for pod security, more granular than K8s PodSecurity admission
- **restricted-v2** — default SCC in OKD 4.x; enforces non-root, drops capabilities, allocates UID from namespace range
- **OpenShift Routes** — Layer 7 ingress with built-in TLS, replaces vanilla K8s Ingress
- **Port 8080 convention** — non-root containers cannot bind port 80; 8080 is the standard
