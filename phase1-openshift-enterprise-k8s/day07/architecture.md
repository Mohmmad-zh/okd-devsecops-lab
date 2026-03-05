# Architecture Diagram — OpenShift Phase 1

## Cluster Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Windows 11 Host (Hyper-V)                                              │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  Ubuntu 22.04 LTS VM  (16 GB RAM, 6 vCPUs, 80 GB disk)           │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────────────────────────────────────┐  │  │
│  │  │  CRC (CodeReady Containers) — OKD 4.20.0 / K8s v1.33.5     │  │  │
│  │  │                                                             │  │  │
│  │  │  ┌──────────────────────────────────────────────────────┐   │  │  │
│  │  │  │  OpenShift Router (HAProxy)                          │   │  │  │
│  │  │  │  *.apps-crc.testing  →  edge TLS termination        │   │  │  │
│  │  │  └──────────────────┬───────────────────────────────────┘   │  │  │
│  │  │                     │ HTTP (internal)                        │  │  │
│  │  │  ┌──────────────────▼───────────────────────────────────┐   │  │  │
│  │  │  │  Namespace: dotnet-demo                              │   │  │  │
│  │  │  │                                                      │   │  │  │
│  │  │  │  NetworkPolicy: default-deny + allow-router-ingress  │   │  │  │
│  │  │  │  ResourceQuota: CPU 2 / RAM 1Gi / Pods 10            │   │  │  │
│  │  │  │  LimitRange: container max 500m CPU / 256Mi RAM      │   │  │  │
│  │  │  │                                                      │   │  │  │
│  │  │  │  ┌────────────────────────────────────────────────┐  │   │  │  │
│  │  │  │  │  Service: aspnetapp (ClusterIP :8080)          │  │   │  │  │
│  │  │  │  └───────────────────┬────────────────────────────┘  │   │  │  │
│  │  │  │                      │                               │   │  │  │
│  │  │  │  ┌───────────────────▼────────────────────────────┐  │   │  │  │
│  │  │  │  │  Deployment: aspnetapp (replicas: 1)           │  │   │  │  │
│  │  │  │  │  SA: aspnetapp-sa  (no token mount)            │  │   │  │  │
│  │  │  │  │  SCC: restricted-v2                            │  │   │  │  │
│  │  │  │  │                                                │  │   │  │  │
│  │  │  │  │  ┌──────────────────────────────────────────┐  │  │   │  │  │
│  │  │  │  │  │  Pod: aspnetapp                          │  │  │   │  │  │
│  │  │  │  │  │  Image: mcr.microsoft.com/dotnet/...     │  │  │   │  │  │
│  │  │  │  │  │  UID:   1000660000 (namespace-allocated) │  │  │   │  │  │
│  │  │  │  │  │  Port:  8080                             │  │  │   │  │  │
│  │  │  │  │  │  CPU:   100m req / 500m lim              │  │  │   │  │  │
│  │  │  │  │  │  RAM:   128Mi req / 256Mi lim            │  │  │   │  │  │
│  │  │  │  │  └──────────────────────────────────────────┘  │  │   │  │  │
│  │  │  │  └────────────────────────────────────────────────┘  │   │  │  │
│  │  │  │                                                      │   │  │  │
│  │  │  │  ┌────────────────────────────────────────────────┐  │   │  │  │
│  │  │  │  │  ImageStream: aspnetapp                        │  │   │  │  │
│  │  │  │  │  :latest → sha256:c0bb56e8...                  │  │   │  │  │
│  │  │  │  │  :v1     → sha256:c0bb56e8... (pinned)         │  │   │  │  │
│  │  │  │  └────────────────────────────────────────────────┘  │   │  │  │
│  │  │  └──────────────────────────────────────────────────────┘   │  │  │
│  │  │                                                             │  │  │
│  │  │  ┌──────────────────────────────────────────────────────┐   │  │  │
│  │  │  │  Namespace: cert-manager                             │   │  │  │
│  │  │  │  cert-manager operator (OLM) — v1.16.5               │   │  │  │
│  │  │  │  Pods: controller, cainjector, webhook               │   │  │  │
│  │  │  │  CRDs: Certificate, Issuer, ClusterIssuer, ...       │   │  │  │
│  │  │  └──────────────────────────────────────────────────────┘   │  │  │
│  │  └─────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

## Traffic Flow

```
User Browser
     │
     │  HTTPS  (TLS terminated at router)
     ▼
OpenShift Router  (HAProxy, *.apps-crc.testing)
     │
     │  HTTP :8080  (plain, inside cluster)
     │  [NetworkPolicy: allow-from-openshift-ingress]
     ▼
Service: aspnetapp  (ClusterIP)
     │
     │  [kube-proxy / OVN-K load balancing]
     ▼
Pod: aspnetapp  (UID 1000660000, non-root)
     │
     │  ASPNETCORE listens on 0.0.0.0:8080
     ▼
  Response → User
```

## RBAC Model

```
aspnetapp-sa (ServiceAccount)
     │
     └── aspnetapp-rolebinding (RoleBinding)
              │
              └── aspnetapp-role (Role, namespace-scoped)
                       │
                       ├── configmaps: get, list, watch
                       ├── secrets:    get
                       └── pods:       get

No ClusterRole. No cross-namespace access.
Token not mounted in pod (automountServiceAccountToken: false).
```

## OLM Operator Install Chain

```
Subscription (cert-manager, stable channel)
     │
     └── InstallPlan (Automatic approval)
              │
              └── CSV: cert-manager.v1.16.5  [Succeeded]
                       │
                       ├── Deployment: cert-manager
                       ├── Deployment: cert-manager-cainjector
                       ├── Deployment: cert-manager-webhook
                       └── CRDs: Certificate, CertificateRequest,
                                  ClusterIssuer, Issuer,
                                  Challenge, Order
```
