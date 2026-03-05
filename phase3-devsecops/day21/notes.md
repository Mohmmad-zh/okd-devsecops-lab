# Day 21 — DevSecOps Architecture Write-Up

## Phase 3 Complete: DevSecOps Integration (Days 15-21)

---

## The DevSecOps Pipeline

```
Developer commits code
        │
        ▼
┌───────────────────────────────────────────────────────────────┐
│                    Security Gates                              │
│                                                               │
│  ① SAST (Day 15)                                             │
│     semgrep scan --config semgrep-rules.yaml --error src/     │
│     Catches: SQL injection, hardcoded secrets, insecure RNG   │
│     Blocks on: ERROR severity findings                        │
│                                                               │
│  ② SCA (Day 17)                                              │
│     dotnet list package --vulnerable                          │
│     Catches: Known CVEs in NuGet dependencies                 │
│     Blocks on: HIGH/CRITICAL vulnerability                    │
│                                                               │
│  ③ Container Build                                            │
│     docker build -t registry/app:SHA                         │
│     (base image: alpine/dotnet — minimal attack surface)      │
│                                                               │
│  ④ Container Scan (Day 16)                                    │
│     trivy image --severity CRITICAL --exit-code 1             │
│     Catches: OS CVEs, language runtime CVEs                   │
│     Blocks on: CRITICAL CVE                                   │
│                                                               │
│  ⑤ Manifest Scan (Day 16)                                     │
│     trivy fs --scanners misconfig gitops-repo/                │
│     Catches: Missing securityContext, RBAC over-permissions   │
│     Blocks on: HIGH/CRITICAL misconfiguration                 │
│                                                               │
│  ⑥ Push to Registry                                           │
│     SBOM generated and attached to image                      │
│                                                               │
│  ⑦ GitOps Promotion (Days 8-14)                              │
│     git push → Argo CD auto-syncs to dev                     │
│     Manual approval → test → prod                             │
└───────────────────────────────────────────────────────────────┘
        │
        ▼
  Runtime Security (Phase 1 foundations)
  - OpenShift SCC (restricted-v2, nonroot-v2)
  - readOnlyRootFilesystem: true
  - NetworkPolicy (default-deny)
  - RBAC + least-privilege ServiceAccounts
        │
        ▼
  Secret Management (Days 18-20)
  - No secrets in YAML or environment vars
  - Vault Kubernetes auth (SA token → short-lived Vault token)
  - Vault AppRole for CI/CD pipelines
  - Memory-backed volume for secret delivery
```

---

## Security Controls Map

| Layer | Control | Tool | Phase |
|-------|---------|------|-------|
| Source code | SAST | Semgrep (custom rules) | Day 15 |
| Dependencies | SCA | `dotnet list --vulnerable` | Day 17 |
| Container image | CVE scan | Trivy | Day 16 |
| K8s manifests | Misconfig scan | Trivy | Day 16 |
| Runtime | SCC, securityContext | OpenShift | Phase 1 |
| Network | NetworkPolicy | OpenShift | Day 3 |
| Access control | RBAC | OpenShift + Argo CD | Day 4, Day 13 |
| Secrets | Dynamic injection | Vault + K8s auth | Days 18-20 |
| GitOps | Audit trail | Argo CD + Gitea | Days 8-14 |

---

## OWASP Top 10 Coverage

| OWASP A0x | Risk | Control in This Lab |
|-----------|------|---------------------|
| A01 Broken Access Control | Over-permissive RBAC | Least-privilege SA, Argo CD AppProject |
| A02 Cryptographic Failures | Weak random, bad TLS | Semgrep rule (CWE-338), TLS Route |
| A03 Injection | SQL, command injection | Semgrep rules (CWE-89, CWE-78) |
| A04 Insecure Design | Exposed internals | Exception detail rule (CWE-209) |
| A05 Security Misconfiguration | Missing readOnlyRootFilesystem | Trivy KSV-0014 |
| A06 Vulnerable Components | Outdated deps | Trivy image scan, SCA |
| A07 Auth Failures | Hardcoded credentials | Semgrep (CWE-798), Vault |
| A08 Data Integrity Failures | Unverified deployments | GitOps + image signing (future) |
| A09 Logging Failures | Exposed stack traces | Semgrep rule (CWE-209) |
| A10 SSRF | N/A for this app | — |

---

## What Was Built and Demonstrated

### Days 15-17: Scanning

```bash
# SAST: Source code vulnerabilities
semgrep scan --config semgrep-rules.yaml --error src/
# Result: 2 blocking findings → fix → 0 findings

# SCA: Vulnerable NuGet dependency
dotnet list package --vulnerable
# Result: Newtonsoft.Json 9.0.1 (HIGH) → upgrade to 13.0.3 → clean

# Container scan: Image CVEs
trivy image --severity CRITICAL --exit-code 1 mcr.microsoft.com/dotnet/samples:aspnetapp
# Result: 0 CRITICAL (alpine:3.23 + .NET 10 = clean)

# Manifest scan: K8s misconfigurations
trivy fs --scanners misconfig --severity HIGH gitops-repo/
# Result: KSV-0014 (readOnlyRootFilesystem missing) → fixed → clean
```

### Days 18-20: Secrets Management

```bash
# Write secrets to Vault
vault kv put secret/aspnetapp/dev db_password="..." api_key="..."

# Pod authenticates via K8s SA token (no static credentials)
# Init container fetches secrets into memory-backed volume
# App reads from /vault-secrets/config.env at startup

# CI/CD uses AppRole (short-lived, 20-minute TTL)
vault write auth/approle/role/lab-cicd secret_id_ttl=10m token_ttl=20m
```

---

## Key Architecture Decisions

### 1. Semgrep over SonarQube
SonarQube requires ~2GB RAM for embedded Elasticsearch — too heavy for a single-node CRC lab. Semgrep is a lightweight, production-grade alternative. Custom YAML rules cover the same patterns.

### 2. Init Container over Vault Agent
The Vault Agent Injector requires the Helm chart to deploy a mutating webhook controller. For OKD compatibility and simplicity, we used a manual init container pattern. In production, use the Vault Operator or Vault Agent Injector.

### 3. GitOps as the Deployment Security Control
Every deployment to test and prod requires a git commit + manual Argo CD sync. This creates:
- Immutable audit trail (git log)
- Human approval gate (no auto-sync to prod)
- Drift prevention (self-heal on dev)

---

## Production Hardening Checklist

From this lab to production:

- [ ] Replace Vault dev mode with Vault Helm chart + Raft storage + Cloud KMS auto-unseal
- [ ] Add image signing (Cosign/Notary) — verify signatures before deployment
- [ ] Enable OPA/Gatekeeper admission policies on OpenShift
- [ ] Add DAST stage (OWASP ZAP) after deployment to dev
- [ ] Configure Argo CD notifications (Slack/Teams on sync/fail)
- [ ] Add Argo CD Image Updater for automated image tag promotion
- [ ] Enable OpenShift audit logging → SIEM
- [ ] Replace self-signed certs with proper PKI (cert-manager + Let's Encrypt or internal CA)
- [ ] Implement Network Policies in all namespaces (default-deny)
- [ ] Add resource quotas to all namespaces to prevent noisy-neighbor attacks
