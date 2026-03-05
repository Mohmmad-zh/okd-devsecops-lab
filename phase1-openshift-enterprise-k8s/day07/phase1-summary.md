# Phase 1 Summary — OpenShift / Enterprise Kubernetes (Days 1–7)

## What Was Built

A production-grade, hardened .NET web application running on OKD 4.20 (OpenShift),
demonstrating enterprise Kubernetes security patterns across seven days.

---

## Deliverables

| Day | Deliverable | Key Files |
|-----|------------|-----------|
| 1 | OKD cluster running; explored OpenShift-specific concepts | `day01/notes.md` |
| 2 | Hardened .NET deployment (non-root, probes, limits, TLS Route) | `day02/deployment.yaml`, `service.yaml`, `route.yaml` |
| 3 | Namespace security hardening | `day03/networkpolicy.yaml`, `resourcequota.yaml`, `limitrange.yaml` |
| 4 | Least-privilege RBAC + dedicated ServiceAccount | `day04/serviceaccount.yaml`, `role.yaml`, `rolebinding.yaml` |
| 5 | cert-manager Operator via OLM; ImageStream with digest pinning | `day05/cert-manager-*.yaml`, `imagestream.yaml` |
| 6 | Failure simulation (CrashLoopBackOff, bad deployment + rollback, self-healing) | `day06/notes.md` |
| 7 | Architecture, security posture, deployment flow documentation | `day07/*.md` |

---

## Live Cluster State (end of Phase 1)

```
Namespace: dotnet-demo
  Deployment:    aspnetapp          1/1 Running
  Service:       aspnetapp          ClusterIP :8080
  Route:         aspnetapp          https://aspnetapp-dotnet-demo.apps-crc.testing
  ServiceAccount: aspnetapp-sa      (token not mounted)
  Role:          aspnetapp-role     (configmaps/secrets/pods read-only)
  NetworkPolicies: 3                (default-deny, allow-router, allow-dns)
  ResourceQuota: dotnet-demo-quota  (CPU/RAM/pod count caps)
  LimitRange:    dotnet-demo-limits (container min/max + defaults)
  ImageStream:   aspnetapp          :latest + :v1 (digest-pinned)

Namespace: cert-manager
  Operator: cert-manager v1.16.5    Succeeded (3/3 pods)
  ClusterIssuer: selfsigned-issuer  Ready: True
```

---

## OpenShift vs Vanilla Kubernetes — Key Differences Encountered

| Feature | Vanilla Kubernetes | OpenShift (OKD) |
|---------|-------------------|-----------------|
| Pod security | PodSecurity admission (namespace labels) | SCC (SecurityContextConstraint) — more granular |
| Default UID | Container's UID (often root) | Namespace-allocated range (e.g. `1000660000+`) |
| Ingress | Ingress resource + controller | Route — built in, TLS edge/passthrough/reencrypt |
| Image tracking | No native concept | ImageStream — digest tracking + change triggers |
| Operator management | Manual Helm / kustomize | OLM (Operator Lifecycle Manager) — updates, deps |
| Image registry | External only | Integrated internal registry |
| Project | Namespace | Project (Namespace + RBAC defaults + annotations) |

---

## Security Controls Summary

```
┌──────────────────────┬──────────────────────────────────────────────────┐
│ Control              │ Setting                                           │
├──────────────────────┼──────────────────────────────────────────────────┤
│ Run as root          │ Blocked (runAsNonRoot: true, SCC restricted-v2)   │
│ Privilege escalation │ Blocked (allowPrivilegeEscalation: false)         │
│ Linux capabilities   │ ALL dropped                                       │
│ Syscall filter       │ seccomp RuntimeDefault                            │
│ UID                  │ 1000660000 (namespace-allocated, not hardcoded)   │
│ SA token             │ Not mounted (automountServiceAccountToken: false) │
│ API access           │ Denied (no token, least-privilege Role)           │
│ Network ingress      │ Router only (NetworkPolicy)                       │
│ Network egress       │ DNS only (NetworkPolicy)                          │
│ CPU limit            │ 500m hard cap (throttled, not killed)             │
│ Memory limit         │ 256Mi hard cap (OOMKilled if exceeded)            │
│ Namespace CPU budget │ 2 total (ResourceQuota)                           │
│ Namespace RAM budget │ 1Gi total (ResourceQuota)                         │
│ Container max        │ 500m CPU / 256Mi RAM (LimitRange)                 │
│ TLS                  │ Edge termination at Router, HTTP→HTTPS redirect   │
└──────────────────────┴──────────────────────────────────────────────────┘
```

---

## Lessons Learned

1. **OpenShift SCC ≠ K8s PodSecurity** — SCC is more powerful: it allocates UIDs,
   controls which capabilities can be added, and integrates with the router/registry.
   Never hardcode `runAsUser` — let OpenShift allocate from the namespace range.

2. **NetworkPolicy requires intent** — Default allow (no policies) is dangerous.
   The correct posture is default-deny everything, then open only what's needed.
   DNS egress is easy to forget and breaks name resolution.

3. **LimitRange + ResourceQuota are complementary** — LimitRange guards individual
   containers; ResourceQuota guards the namespace as a whole. You need both.

4. **Readiness probes are the blast shield** — Without them, a bad deployment
   immediately serves traffic. With them, the rollout stalls on the new pod and
   the old pod keeps serving — zero downtime even for broken deployments.

5. **OLM OperatorGroup install modes matter** — Many operators require AllNamespaces
   mode (`spec: {}`). OwnNamespace mode is not universally supported.

6. **ImageStreams enable GitOps-friendly CD** — By pinning digests and supporting
   scheduled imports, ImageStreams decouple your deployment manifests from registry
   URLs. Promoting `:latest` to `:v1` is a one-line release gate.

---

## Phase 2 Preview — GitOps with Argo CD (Days 8–14)

The manifests built in Phase 1 (`day02/`, `day03/`, `day04/`) will be moved into
a Git repository and managed by Argo CD. Instead of `oc apply`, changes flow through:

```
Git commit → Argo CD detects drift → Sync to cluster
```

The `platform-gitops/` directory structure (base + overlays) will be built on Day 9.
