# OKD / DevSecOps 30-Day Lab

A personal learning project. I built a full DevSecOps platform from scratch over 30 days
on my Windows laptop using OKD (community OpenShift). This repo documents everything I did,
every mistake I made, and how I fixed it.

---

## About the Credentials in This Repo

You'll see passwords, tokens, and API keys throughout the notes files. They look like this:

```
kubeadmin password: WD2J7-fZZr9-XFXIn-qxDvg
Vault root token:   root
Nexus password:     nexus-admin-2024!
Grafana password:   grafana-admin-2024!
```

**These are safe to publish because:**

- Every service (OKD, Vault, Nexus, Gitea, Grafana) runs inside a KVM virtual machine
  on my local laptop. The VM has no public IP — it only has a private Hyper-V network
  adapter and is completely unreachable from the internet.
- The domains (`*.apps-crc.testing`, `api.crc.testing`) are fake local-only DNS entries
  that only resolve inside the CRC VM's host. They don't exist on the public internet.
- The Vault instance runs in dev mode (`vault server -dev`) — it resets to empty on every
  restart and has no persistent secrets.
- The Gitea API token is for a Gitea server inside the cluster. Even if someone had the
  token, they'd have no way to reach the server.
- The kubeadmin password changes every time you run `crc delete && crc start`.

**In short:** copying these credentials gives you zero access to anything.
They're kept in the notes because this is a real learning journal,
and sanitizing them would make the notes less useful as a reference.

---

## What This Is

A full DevSecOps platform built on a single Windows laptop:

| Layer | Tools |
|-------|-------|
| Cluster | OKD 4.20 (community OpenShift) via CRC 2.58.0, single-node |
| Application | ASP.NET 8 on .NET — hardened, non-root, resource-limited |
| GitOps | Gitea (private Git) + Argo CD — auto-sync, self-healing |
| Secrets | HashiCorp Vault — KV engine, Kubernetes auth, AppRole |
| Registry | Sonatype Nexus OSS — Docker hosted/proxy + NuGet proxy |
| Security | Semgrep (SAST) + Trivy (container scan) + dotnet SCA + SBOM |
| IaC | Terraform (Kubernetes provider) + Ansible (role-based playbooks) |
| Monitoring | Prometheus + Grafana — annotation-based scraping, custom dashboard |

---

## Environment

| | |
|-|-|
| Host | Windows 11 Enterprise, Hyper-V |
| VM | Ubuntu 22.04 LTS, 16GB RAM, 80GB disk, 6 vCPUs |
| Cluster | OKD 4.20.0 / CRC 2.58.0 / Kubernetes v1.33.5 |
| Nested virt | KVM inside Hyper-V (requires `ExposeVirtualizationExtensions $true`) |

---

## Progress — All 30 Days

| Day | What I Did | Status |
|-----|-----------|--------|
| **Phase 1 — OpenShift Fundamentals** | | |
| 1 | Install OKD/CRC, explore Projects, Routes, ImageStreams, SCC, RBAC | ✅ |
| 2 | Deploy hardened .NET 8 app (non-root, liveness/readiness probes, resource limits) | ✅ |
| 3 | Security hardening — SecurityContext, NetworkPolicy, ResourceQuota, LimitRange | ✅ |
| 4 | RBAC and ServiceAccounts — custom Role, least-privilege binding | ✅ |
| 5 | Operators and ImageStreams — deploy cert-manager Operator, use ImageStream | ✅ |
| 6 | Failure simulation — pod crash, OOM kill, bad deployment rollout | ✅ |
| 7 | Architecture documentation — security posture, deployment flow diagram | ✅ |
| **Phase 2 — GitOps with Argo CD** | | |
| 8 | Install Gitea + Argo CD, first Application sync | ✅ |
| 9 | GitOps repo structure — Kustomize base + dev/test/prod overlays | ✅ |
| 10 | Auto-sync + self-healing — Argo CD restores deleted Service in <5s | ✅ |
| 11 | Promotion strategy — dev→test→prod with manual approval gate | ✅ |
| 12 | Rollback simulation — git revert as the production rollback mechanism | ✅ |
| 13 | Argo CD security — AppProject resource whitelist, RBAC, sync windows | ✅ |
| 14 | GitOps patterns documentation | ✅ |
| **Phase 3 — DevSecOps** | | |
| 15 | SAST — Semgrep with custom C# rules, pipeline fails on ERROR severity | ✅ |
| 16 | Container scanning — Trivy image + manifest, blocks on CRITICAL CVE | ✅ |
| 17 | Dependency scanning — dotnet SCA + CycloneDX SBOM generation | ✅ |
| 18 | HashiCorp Vault — deploy on OKD, KV v2 engine, basic secrets | ✅ |
| 19 | Vault + Kubernetes integration — K8s auth, dynamic secret injection via init container | ✅ |
| 20 | Vault AppRole for CI/CD pipelines — short-lived tokens, no static credentials | ✅ |
| 21 | DevSecOps architecture write-up | ✅ |
| **Phase 4 — Enterprise Toolchain** | | |
| 22 | Nexus Repository OSS — Docker hosted/proxy repos + NuGet hosted/proxy | ✅ |
| 23 | Pipeline + Nexus — SHA-tagged immutable images, GitOps promotion end-to-end | ✅ |
| 24 | Terraform — Kubernetes provider, monitoring namespace, RBAC, drift detection | ✅ |
| 25 | Ansible — role-based playbook, tool verification, idempotent (changed=0) | ✅ |
| 26 | Terraform + Ansible combined — Terraform provisions, Ansible verifies + configures | ✅ |
| 27 | Prometheus + Grafana — annotation-based pod scraping, Grafana dashboard via API | ✅ |
| 28 | Real incident — disk pressure cascade, pod eviction storm, cluster recovery | ✅ |
| 29 | Enterprise architecture diagram | ✅ |
| 30 | Portfolio write-up | ✅ |

---

## Repository Structure

```
okd-devsecops-lab/
├── README.md                              ← this file
├── SETUP.md                               ← full environment setup + troubleshooting log
│
├── phase1-openshift-enterprise-k8s/
│   ├── day01/   notes.md + manifests      ← OKD install, OpenShift concepts
│   ├── day02/   notes.md + deployment.yaml
│   ├── day03/   notes.md + networkpolicy.yaml, quota.yaml
│   ├── day04/   notes.md + rbac.yaml
│   ├── day05/   notes.md + cert-manager manifests
│   ├── day06/   notes.md + failure scenarios
│   └── day07/   notes.md + architecture docs
│
├── phase2-gitops-argocd/
│   ├── day08/   notes.md + argocd app manifests
│   ├── day09/   notes.md + kustomize base/overlays
│   ├── day10/   notes.md (self-healing demo)
│   ├── day11/   notes.md (promotion walkthrough)
│   ├── day12/   notes.md (rollback walkthrough)
│   ├── day13/   notes.md + appproject.yaml, policy.csv
│   └── day14/   notes.md
│
├── phase3-devsecops/
│   ├── day15/   notes.md + semgrep-rules.yaml
│   ├── day16/   notes.md (Trivy scan results)
│   ├── day17/   notes.md + sbom output
│   ├── day18/   notes.md + vault.yaml
│   ├── day19/   notes.md + vault-demo.yaml
│   ├── day20/   notes.md (AppRole pipeline demo)
│   └── day21/   notes.md (architecture write-up)
│
└── phase4-enterprise-toolchain/
    ├── day22/   notes.md + nexus.yaml
    ├── day23/   notes.md (pipeline demo)
    ├── day24/   notes.md + main.tf
    ├── day25/   notes.md + site.yml + roles/
    ├── day26/   notes.md + main.tf + configure_staging.yml
    ├── day27/   notes.md + prometheus-deployment.yaml + grafana-deployment.yaml
    ├── day28/   incident-report.md
    ├── day29/   architecture.md
    └── day30/   PORTFOLIO.md ← full narrative write-up
```

---

## Notable Things That Broke (and How I Fixed Them)

A sample — every day's `notes.md` has the full details.

**OpenShift SCC (Security Context Constraints)**
Tried to set `runAsUser: 1000` on an app. Broke immediately. OpenShift assigns UIDs
from a namespace range automatically — hardcoding a UID outside that range is rejected.
Fix: remove `runAsUser`, set only `runAsNonRoot: true`.

**Argo CD + Gitea TLS**
Argo CD couldn't connect to Gitea (self-signed cert). Three flags required that no
tutorial mentioned together: `--insecure-skip-server-verification`, `--grpc-web`,
and using an API token instead of password.

**JFrog Artifactory vs Nexus**
Tried Artifactory first. It needs 2GB of memory and the cluster was at 89% already.
Switched to Nexus OSS (1GB request) — same features, smaller footprint.

**CRI-O image pull TLS**
Pushed app image to Nexus. Pod failed: `x509: certificate signed by unknown authority`.
CRI-O (the container runtime) doesn't trust OKD's self-signed wildcard cert.
Fix: push to the OpenShift internal registry instead, which the cluster already trusts.

**Disk pressure cascade (Day 28 — actual P1 incident)**
The OKD marketplace operator was re-pulling a 1.27GB catalog index image every 30 minutes.
Disk hit 85%, kubelet set DiskPressure: True. I tried to tolerate the taint so Prometheus
could start — this caused a pod eviction loop (65+ pods created/evicted in 10 minutes) that
saturated disk I/O until the API server fell over and the VM stopped.
Fix: expand the QCOW2 disk image (`qemu-img resize +20G`), restart CRC, never tolerate
pressure taints during active disk pressure.

---

## The Detailed Write-up

See [phase4-enterprise-toolchain/day30/PORTFOLIO.md](phase4-enterprise-toolchain/day30/PORTFOLIO.md)
for the full narrative — what I built, what broke, what I'd do differently.

---

*OKD 4.20 / CRC 2.58.0 / Windows 11 Hyper-V*
