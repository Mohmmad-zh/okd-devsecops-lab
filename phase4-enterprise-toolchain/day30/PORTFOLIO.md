# 30-Day OKD/DevSecOps Lab — What I Built and Everything I Broke Along the Way

I'm a junior DevOps engineer and I wanted to actually understand enterprise toolchains,
not just watch tutorials. So I spent 30 days building one from scratch on my Windows laptop.
This is the honest write-up — including all the times things broke and I had no idea why.

---

## What I Built

A full DevSecOps platform on OKD (the open-source version of Red Hat OpenShift), running
inside a Linux VM on my Windows machine. By the end, it had:

- A Kubernetes cluster (OKD 4.20) running locally via CRC
- A .NET web app deployed and hardened according to security best practices
- GitOps with Argo CD — every deployment triggered by a git commit
- Vault for secrets management (no passwords in code)
- Nexus as a private artifact registry
- Trivy and Semgrep scanning every build
- Terraform for infrastructure-as-code
- Ansible for configuration management
- Prometheus + Grafana for monitoring

Here's the git repo: everything is documented in `notes.md` files under each day's folder.

---

## Phase 1 — Getting OKD Running (Days 1–7)

### What I was trying to do

Install OpenShift locally and deploy a .NET app with proper security settings
(no running as root, network isolation, RBAC, TLS certs).

### Day 1 — Setting up OKD

I tried to use CRC (OpenShift Local) to run OKD on my Windows machine.
The first thing that tripped me up: CRC on Linux requires KVM/nested virtualization.
My VM is inside Hyper-V, so I needed to enable nested virtualization on the Hyper-V VM first.

```powershell
# Had to run this on Windows before the VM could run KVM
Set-VMProcessor -VMName "Ubuntu 22.04 LTS" -ExposeVirtualizationExtensions $true
```

I also had to disable Hyper-V Dynamic Memory — with dynamic memory enabled, the VM
only got ~4.8GB at runtime even though I'd allocated 16GB. That caused CRC to fail
immediately because it needs at least 9GB.

Then I couldn't create a Red Hat account (website error), so I used the OKD preset
which doesn't need a pull secret. That actually worked fine.

**What I learned:** Read the prerequisites carefully. "16GB RAM" doesn't help if the
hypervisor is dynamically giving the VM less.

---

### Day 2–3 — Deploying the .NET App

Getting the app to run on OpenShift was harder than on plain Kubernetes.
OpenShift's security model is stricter — by default, pods can't run as root.

The error I kept seeing:
```
Error creating: pods "aspnetapp" is forbidden: unable to validate against any
security context constraint: [provider "restricted": Forbidden: not available]
```

I spent a long time trying to fix this. The solution was to NOT hardcode `runAsUser`
in the pod spec. OpenShift's `restricted-v2` SCC assigns UIDs automatically from a
namespace range (like `1000660000`). The moment I added `runAsUser: 1000`, it broke
because that wasn't in the allowed range.

```yaml
# WRONG — don't hardcode UIDs in OpenShift
securityContext:
  runAsUser: 1000

# CORRECT — let OpenShift assign the UID
securityContext:
  runAsNonRoot: true
```

**What I learned:** OpenShift's security model is different from vanilla Kubernetes.
Don't fight it — work with it.

---

### Day 4 — RBAC

I tried to grant a ServiceAccount the `anyuid` SCC using the command I found in docs:
```bash
oc adm policy add-scc-to-serviceaccount -z my-sa -n my-ns anyuid
```

That returned an error. Turns out the `-z` flag was removed in OKD 4.20.
The replacement is a ClusterRoleBinding:

```bash
oc create clusterrolebinding my-sa-anyuid \
  --clusterrole=system:openshift:scc:anyuid \
  --serviceaccount=my-ns:my-sa
```

I found this by reading the OKD 4.20 release notes after about 30 minutes of
searching Stack Overflow for the wrong thing.

---

## Phase 2 — GitOps with Argo CD (Days 8–14)

### What I was trying to do

Set up Gitea as a private Git server and Argo CD for GitOps deployments.
Make it so that pushing to git automatically deploys to the cluster.

---

### Day 8 — Installing Gitea and Argo CD

**Gitea broke immediately.** The image uses s6-overlay for init, which requires
running as root during startup. But I set `runAsUser: 1000` in the pod spec
(from habit after Day 2). The init system failed silently.

Fix: remove `runAsUser` entirely and grant the ServiceAccount `anyuid` SCC.
The catch: you can't set ANY `runAsUser` — not even the correct UID — or the
init system breaks. It needs to start as root and then drop privileges itself.

**Argo CD Redis also broke.** Redis runs as UID 999, which isn't in the
namespace's allowed range. I had to grant `nonroot-v2` SCC and remove the
`runAsUser` from the pod template. Also removed some old seccomp annotations
that were leftover from the Helm chart and conflicted with OKD 4.20.

**Argo CD couldn't connect to Gitea.** I tried adding the repo:
```bash
argocd repo add https://gitea-gitea.apps-crc.testing/gitops/aspnetapp.git \
  --username gitops \
  --password gitops123!
```
This failed with a TLS error. The fix required three flags I didn't know about:
- `--insecure-skip-server-verification` — Gitea uses a self-signed cert
- `--grpc-web` — required in my setup, gRPC didn't work without it
- Use API token instead of password (Gitea rejected password auth for some repos)

```bash
argocd repo add https://gitea-gitea.apps-crc.testing/gitops/aspnetapp.git \
  --username gitops \
  --password 7709e7fe2133803c... \  # API token, not password
  --insecure-skip-server-verification \
  --grpc-web
```

**What I learned:** Every tool has its own quirks with OpenShift. Read the SCC
requirements for each image before deploying it.

---

### Day 10 — Auto-Sync and Self-Healing

This was actually the most satisfying day. I deleted a Service directly on the cluster
(bypassing GitOps, like someone would in a real incident):

```bash
oc delete svc aspnetapp -n aspnetapp-dev
```

Argo CD detected the drift and restored it in under 5 seconds. Seeing that work
for the first time made the whole GitOps concept click for me.

---

### Day 13 — Argo CD Security

I had to add a `Namespace` resource to the AppProject's `clusterResourceWhitelist`.
Namespace is a cluster-scoped resource (not namespace-scoped), and Argo CD's default
AppProject doesn't allow creating them.

This cost me about an hour because the error message said "resource not permitted"
without telling me it was specifically the Namespace resource type.

---

## Phase 3 — DevSecOps (Days 15–21)

### What I was trying to do

Add security scanning to the pipeline: static analysis, container scanning,
dependency scanning, and secrets management with Vault.

---

### Day 15 — SAST with Semgrep

I originally planned to use SonarQube. Checked memory usage:
```bash
oc top pods -n sonarqube
# sonarqube-xxx  2847m  2103Mi
```

My cluster was at 89% memory. SonarQube needs at least 2Gi. Not happening.

Switched to Semgrep, which runs as a CLI tool (no server needed, ~200MB).
Same security value, but actually fits in the cluster. I also wrote custom
C# rules specific to the app — things like detecting hardcoded connection strings
and missing input validation.

**What I learned:** Tools need to fit your environment. The best tool you can't run
is worse than a good tool you can run.

---

### Day 16 — Trivy Container Scanning

Trivy was easy to install. The one thing that caught me off guard:
```bash
trivy image --severity CRITICAL --exit-code 1 mcr.microsoft.com/dotnet/samples:aspnetapp
# Exit code 0 — 0 CRITICAL CVEs
```

I was surprised the Microsoft sample image passed with zero criticals.
It's because it's based on Alpine 3.23 which is very lean. Good to know —
the base image choice matters enormously for security.

---

### Day 18–19 — HashiCorp Vault

Installing Vault on OKD required a flag I'd never seen before:
```yaml
env:
  - name: SKIP_SETCAP
    value: "true"
```

Vault normally tries to set Linux capabilities (for memory locking),
but that requires privileges it doesn't have in a container on OKD.
`SKIP_SETCAP=true` tells it to skip that step.

Setting up Kubernetes auth was the hardest part of the whole lab.
The sequence is: create a Vault role → create a K8s ServiceAccount →
bind them → test with an init container that fetches the secret.

When it finally worked and I could see the secret injected into the
pod without storing it anywhere, that was another "aha" moment.

---

## Phase 4 — Enterprise Toolchain (Days 22–30)

### Day 22 — Nexus Repository

**First mistake: tried JFrog Artifactory.** It needs 2Gi of memory.
Cluster was already at 89% memory. Pod went Pending immediately.

Switched to Sonatype Nexus OSS (1Gi request). Same features, smaller footprint.

**Second mistake: wrong realm name in the API call.**
```bash
# What I tried (WRONG):
"NexusAuthorizingRealm"

# What it actually is:
"NexusAuthenticatingRealm"
```

Spent 20 minutes on this. The Nexus REST API returned 400 with no helpful message.
Had to find the right realm name by reading the Nexus source code on GitHub.

**Third problem: no docker or podman on the VM.**
I needed to push images to Nexus. The VM only had the OKD client tools.
Solution: installed `skopeo`, which copies container images between registries
without needing a Docker daemon:

```bash
skopeo copy \
  docker://docker.io/alpine:3.19 \
  docker://localhost:8082/alpine:3.19 \
  --dest-creds="cicd-user:cicd-pass-2024!" \
  --dest-tls-verify=false
```

---

### Day 23 — Pipeline Integration with Nexus

Ran Trivy → passed → pushed image to Nexus with a SHA tag → updated the
GitOps deployment.yaml → Argo CD synced. The full pipeline working end-to-end.

But then the pod wouldn't start:
```
Failed to pull image: x509: certificate signed by unknown authority
```

The OKD cluster doesn't trust its own wildcard certificate when pulling images.
CRI-O (the container runtime) needs to trust the registry's TLS cert.

Options I found:
1. Add the OKD CA to the cluster trust bundle (requires MachineConfig rollout = node restart)
2. Configure it as an insecure registry (same issue)
3. Use cert-manager with Let's Encrypt (correct production approach)
4. Push to the OpenShift internal registry which the cluster already trusts

I went with option 4 for the lab. Changed the image reference to:
```
image-registry.openshift-image-registry.svc:5000/aspnetapp-dev/aspnetapp:a3f8b2c
```

Pod started immediately. Argo CD showed Synced + Healthy.

**Also hit disk pressure during this day.** The cluster's data partition filled to 85%
from all the images accumulated over previous days. Kubelet set `DiskPressure: True`
and stopped scheduling new pods. Fixed it by scaling down Nexus temporarily to allow
its 646MB image to be garbage collected, then pruning unused images:

```bash
oc scale deployment nexus -n nexus --replicas=0
# wait for pod to terminate
oc exec -n openshift-machine-config-operator <mcd-pod> -- \
  chroot /rootfs crictl rmi --prune
# disk usage dropped from 85% to 83%
oc scale deployment nexus -n nexus --replicas=1
```

---

### Day 24 — Terraform

Terraform's Kubernetes provider worked well. Interesting discovery: every time
I ran `terraform plan`, it wanted to remove some annotations from my resources.

```hcl
# Terraform says:
- "openshift.io/sa.scc.mcs"                = "s0:c28,c12" -> null
- "openshift.io/sa.scc.supplemental-groups" = "1000780000/10000" -> null
```

These aren't drift — OKD automatically adds these annotations to every namespace
and ServiceAccount. Terraform doesn't know about them and wants to delete them.

In production you'd fix this with `ignore_changes` in the lifecycle block.
For the lab I left it as-is since the apply doesn't actually break anything —
OKD just re-adds the annotations immediately after.

---

### Day 25 — Ansible

Ansible was already installed on the VM. Wrote a playbook with three roles:
- `security_tools`: verify Trivy, Semgrep, Skopeo are installed
- `devops_tools`: verify Terraform, Vault CLI, Argo CD CLI
- `cluster_verification`: check cluster connectivity and all namespaces

First run:
```bash
ansible-playbook site.yml
# WARNING: provided hosts list is empty
# skipping: no hosts matched
```

Forgot the inventory file flag:
```bash
ansible-playbook -i inventory.ini site.yml
# ok=23  changed=0  unreachable=0  failed=0
```

`changed=0` means it's idempotent — running it again won't make any changes
because everything is already in the correct state.

---

### Day 26 — Terraform + Ansible Together

The idea: Terraform provisions infrastructure → Ansible configures it.

Added a "handshake check" in Ansible — before making any changes, it verifies
the namespace was created by Terraform:

```yaml
- name: Verify namespace was created by Terraform
  ansible.builtin.command: >
    oc get namespace aspnetapp-staging
    -o jsonpath='{.metadata.labels.managed-by}'
  register: ns_managed_by
  failed_when: ns_managed_by.stdout != "terraform"
```

If someone manually created the namespace (outside Terraform), Ansible would
refuse to configure it. This prevents accidents.

---

### Day 27 — Prometheus and Grafana

The monitoring namespace already had everything Prometheus needed from Day 24
(ServiceAccount, ClusterRole, ConfigMap with scrape config, PVC).

Deployed Prometheus and Grafana. Grafana came up immediately. Prometheus kept
getting evicted because the disk was at 85% again.

**The disk problem was now chronic.** Every time I freed space, the OKD marketplace
operator re-pulled the `community-operator-index:v4.20` image (1.27GB). It does this
on a schedule. So I'd free 1.2GB, it would re-fill within minutes.

**Also locked myself out of Grafana.** Tried several wrong passwords, and Grafana
locks the account after too many failures. The fix was to reset via the CLI:

```bash
oc exec -n monitoring <grafana-pod> -- \
  grafana-cli admin reset-admin-password 'grafana-admin-2024!'
```

But then the pod had a second copy starting (rolling update from an env change I made),
and both were trying to write to the same SQLite database simultaneously → "database is locked".
Had to scale Grafana to 0, then back to 1, to get a clean start.

Eventually confirmed it was working by querying the Grafana API:

```bash
curl -u 'admin:grafana-admin-2024!' http://localhost:3000/api/datasources
# Prometheus datasource → http://prometheus.monitoring.svc.cluster.local:9090
```

---

### Day 28 — Real Incident (Not Simulated)

Honestly, I didn't plan this one. The disk pressure situation escalated into an actual
cluster outage while I was working on Day 27.

Timeline of what happened:
- Disk at 85%, kubelet sets DiskPressure: True
- I tried to add a `disk-pressure` toleration to Prometheus so it could start
- This was a mistake. Pods could now be admitted but were immediately evicted
- The Deployment controller saw the evicted pod and created a new one
- New pod → evicted → new pod → evicted — 65+ times in ~10 minutes
- All the overlay filesystem cleanup from the evictions saturated disk I/O
- etcd's write-ahead log couldn't write → API server stopped responding
- `crc status` showed: "CRC VM: Stopped"

The cluster crashed.

I actually learned more from this than from any tutorial. The "fix" I tried
(tolerate the taint) made things catastrophically worse. The correct approach
is: don't schedule pods onto a node under disk pressure — fix the disk first.

**Recovery:**
```bash
crc start
# Cluster came back, all PVC-backed data survived
```

**Real fix (to prevent recurrence):**
```bash
# Permanently fix the disk — expand the QCOW2 image
crc stop
sudo qemu-img resize /home/ubuntu/.crc/machines/crc/crc.qcow2 +20G
crc start
# CRC automatically ran: "Resizing /dev/vda4 filesystem"
# Disk went from 31GB to 51GB, usage dropped from 85% to 51%
# DiskPressure: False — Prometheus started cleanly
```

**5 Whys:**
1. Why did the cluster crash? → etcd I/O stalled under disk pressure
2. Why was disk I/O so high? → 65+ pod evictions creating overlay FS churn
3. Why were pods being evicted in a loop? → I added a disk-pressure toleration
4. Why was disk pressure active? → marketplace operator continuously re-pulling 1.27GB image
5. Why didn't I catch this earlier? → No monitoring. Prometheus couldn't start because of the condition it was supposed to monitor

That last one is what they call a "bootstrapping problem" and it's a real thing in production.

---

## Skills I Actually Have Now (vs. Skills I Just Knew About Before)

| Skill | Before | After |
|-------|--------|-------|
| OpenShift SCC | Heard of it | Debug `anyuid` vs `restricted-v2`, know exactly what breaks what |
| Argo CD | Knew it syncs git | Set up AppProject restrictions, RBAC, sync windows |
| Vault | Knew it stores secrets | K8s auth, AppRole, init-container secret injection |
| Terraform | Wrote basic configs | Provider auth, drift detection, state, OKD annotation quirks |
| Ansible | Wrote basic playbooks | Roles, idempotency, `changed_when: false`, inventory |
| Incident response | Theory | Diagnosed and resolved a real P1 cluster outage |
| TLS in Kubernetes | Vague understanding | OKD self-signed certs, CRI-O trust, cert-manager, skopeo flags |
| Disk management in K8s | Never thought about it | crictl image GC, DiskPressure mechanics, QCOW2 expansion |

---

## Things I'd Do Differently

**1. Check cluster capacity before deploying anything new.**
I kept hitting memory and disk limits because I didn't track usage proactively.
Should have set up `oc top nodes` as a habit from Day 1.

**2. Don't hardcode runAsUser in OpenShift.**
Wasted hours on SCC errors that went away the moment I removed the UID from the spec.

**3. Fix the root cause, not the symptom.**
The disk-pressure toleration "fix" is a perfect example of a workaround that made things
catastrophically worse. When a node is under pressure, the right answer is to relieve the
pressure — not to make it easier to schedule more pods.

**4. Use SHA-tagged images from the start.**
I used `:latest` in the first few days and had a confusing deployment issue where I couldn't
tell which version was running. After switching to SHA tags, I could always trace exactly
what was deployed and when.

**5. Test Argo CD repo connectivity before assuming it works.**
I pushed changes to Gitea and waited minutes for Argo CD to sync, not realizing it couldn't
even connect to the repo. Added `argocd app get <app> --grpc-web` to check sync status as
a habit after that.

---

## What's Running Now (End of Day 30)

```
NAMESPACE         PODS    SERVICE
argocd            7       argocd-server-argocd.apps-crc.testing
aspnetapp-dev     1       aspnetapp-dev.apps-crc.testing
vault             1       vault.apps-crc.testing
nexus             1       nexus.apps-crc.testing
monitoring        2       prometheus-monitoring.apps-crc.testing
                          grafana-monitoring.apps-crc.testing

Node: crc — DiskPressure: False, Ready: True
Disk: 29GB / 51GB (57%)
```

---

## If You Want to Try This

The full repo is structured so each day is standalone. You can start at Day 1 and
follow along, or jump to any phase. Every `notes.md` has the actual commands I ran,
the errors I got, and what fixed them.

Minimum requirements: 16GB RAM, 80GB disk, Windows with Hyper-V or Linux with KVM.
The nested virtualization for CRC inside a Hyper-V VM is the trickiest part to set up —
see `SETUP.md` for the exact steps.

---

*Built on: OKD 4.20 / CRC 2.58.0 / Windows 11 Hyper-V*
*Duration: 30 days*
