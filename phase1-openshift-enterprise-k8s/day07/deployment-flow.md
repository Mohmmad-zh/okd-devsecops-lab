# Deployment Flow — aspnetapp on OpenShift

## End-to-End Request Flow

```
                         HTTPS Request
                              │
                    ┌─────────▼──────────┐
                    │   Client Browser   │
                    └─────────┬──────────┘
                              │ TLS (port 443)
                              │ SNI: aspnetapp-dotnet-demo.apps-crc.testing
                              ▼
                    ┌─────────────────────────┐
                    │   OpenShift Router      │
                    │   (HAProxy)             │
                    │                         │
                    │  TLS edge termination   │
                    │  HTTP → HTTPS redirect  │
                    └─────────┬───────────────┘
                              │ HTTP :8080 (plaintext inside cluster)
                              │ [NetworkPolicy: allow-from-openshift-ingress]
                              ▼
                    ┌─────────────────────────┐
                    │   Service: aspnetapp    │
                    │   ClusterIP :8080       │
                    └─────────┬───────────────┘
                              │ kube-proxy / OVN-K
                              ▼
                    ┌─────────────────────────┐
                    │   Pod: aspnetapp        │
                    │   UID: 1000660000       │
                    │   :8080 (Kestrel)       │
                    │                         │
                    │   Readiness: ✅          │
                    │   Liveness:  ✅          │
                    └─────────────────────────┘
```

## Deployment Lifecycle (Day 2 → Day 4 changes)

```
Day 2                          Day 4 (added)
─────────────────────────────────────────────────────────
oc apply deployment.yaml       serviceAccountName: aspnetapp-sa
                               automountServiceAccountToken: false
      │
      ▼
  ReplicaSet created
      │
      ▼
  Pod scheduled on node
      │
      ├─ SCC admission check (restricted-v2) ──→ PASS
      ├─ LimitRange injection (if missing)   ──→ applied
      ├─ ResourceQuota check                 ──→ PASS (within budget)
      │
      ▼
  Container starts (UID 1000660000)
      │
      ├─ initialDelaySeconds: 10
      │
      ▼
  Readiness probe passes (GET / :8080 → 200)
      │
      ▼
  Pod added to Service endpoints
      │
      ▼
  Traffic routed via Route → Service → Pod
```

## Rolling Update Flow (normal)

```
oc set image / oc apply (new image tag)
           │
           ▼
     New ReplicaSet created
           │
           ▼
     New Pod scheduled
           │
     ┌─────▼──────┐
     │ Readiness  │ ← must pass before old pod is removed
     │ probe check│
     └─────┬──────┘
           │ PASS                          FAIL (e.g. ImagePullBackOff)
           ▼                                    ▼
  Old pod terminated              Old pod stays Running
  New pod serves traffic          New pod stuck — rollout paused
                                       │
                                       ▼
                                  oc rollout undo
                                       │
                                       ▼
                                  Old ReplicaSet scaled back up
                                  New ReplicaSet scaled to 0
```

## Image Update Flow (ImageStream)

```
mcr.microsoft.com/dotnet/samples:aspnetapp
           │
           │  oc import-image / scheduled (every 15 min)
           ▼
  ImageStream: aspnetapp
  Tag: :latest → sha256:c0bb56e8...
  Tag: :v1     → sha256:c0bb56e8... (pinned release)
           │
           │  (optional) image change trigger on Deployment
           ▼
  Deployment rolls out new pod with updated digest
```

## Rollback Decision Tree

```
Deployment not healthy?
        │
        ├─ ImagePullBackOff?
        │       → oc rollout undo deployment/aspnetapp -n dotnet-demo
        │
        ├─ CrashLoopBackOff?
        │       → oc logs <pod> --previous
        │       → fix app / config, push corrected image
        │       → oc rollout undo (if quick fix needed)
        │
        ├─ Readiness failing?
        │       → oc describe pod <name>  (check events)
        │       → oc logs <name>          (check app startup errors)
        │
        └─ OOMKilled?
                → oc describe pod <name>  (look for OOMKilled)
                → increase limits in deployment.yaml
                → oc apply -f day02/deployment.yaml
```

## Resource Flow: How Limits Are Enforced

```
LimitRange (namespace default injector)
    ↓  injects defaults if container omits requests/limits
Container spec  →  ResourceQuota check (namespace budget)
    ↓  if over budget → admission denied
Pod scheduled on node  →  cgroups applied
    │
    ├─ CPU throttled at 500m (not killed)
    └─ Memory OOMKilled at 256Mi
```
