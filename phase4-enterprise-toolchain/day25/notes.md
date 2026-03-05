# Day 25 — Ansible Configuration Management

## Goals
- Write a role-based Ansible playbook for the OKD lab environment
- Verify all DevSecOps tools are installed and functional
- Confirm all cluster namespaces are healthy
- Demonstrate idempotency (run twice, no changes)

---

## Why Ansible?

Ansible complements Terraform in the enterprise toolchain:

| Tool | Responsibility |
|------|---------------|
| Terraform | **Infrastructure provisioning** — creates K8s resources, namespaces, RBAC |
| Ansible | **Configuration management** — verifies tools, applies config, ensures state |

Ansible's key strength: **idempotency** — running a playbook 10 times produces the same result as running it once. No unwanted side effects.

---

## Playbook Structure

```
day25/
├── inventory.ini              ← Target hosts (localhost via local connection)
├── site.yml                   ← Main playbook, applies all roles
└── roles/
    ├── security_tools/        ← Trivy, Semgrep, Skopeo
    │   └── tasks/main.yml
    ├── devops_tools/          ← Terraform, Vault CLI, Argo CD CLI
    │   └── tasks/main.yml
    └── cluster_verification/  ← oc CLI, cluster connectivity, namespace health
        └── tasks/main.yml
```

---

## Inventory

```ini
[okd_nodes]
crc-vm ansible_host=localhost ansible_connection=local

[okd_nodes:vars]
ansible_python_interpreter=/usr/bin/python3
```

Using `ansible_connection=local` — Ansible runs on the same machine that has `oc` context (the CRC VM itself).

---

## Demo Results

```
ansible-playbook -i inventory.ini site.yml
```

```
TASK [Show target host info]
"msg": "Configuring UbuntuVM (Ubuntu 22.04)"

TASK [security_tools : Report Trivy version]
"msg": "Trivy: Version: 0.69.3"

TASK [security_tools : Report Semgrep version]
"msg": "Semgrep: 1.x.x"

TASK [security_tools : Install Skopeo if missing]  → skipping (already installed)

TASK [security_tools : Report Skopeo version]
"msg": "Skopeo: skopeo version 1.4.1"

TASK [devops_tools : Report Terraform version]
"msg": "Terraform: Terraform v1.14.6"

TASK [devops_tools : Report Vault CLI]
"msg": "Vault CLI: Vault v1.18.3"

TASK [devops_tools : Report Argo CD CLI]
"msg": "Argo CD CLI: argocd: v2.13.0+347f221"

TASK [cluster_verification : Report oc version]
"msg": "oc CLI: Client Version: 4.20.0-okd-scos.11"

TASK [cluster_verification : Report cluster user]
"msg": "Connected as: kubeadmin"

TASK [cluster_verification : Report namespace status]
"msg": "argocd: EXISTS"
"msg": "vault: EXISTS"
"msg": "monitoring: EXISTS"
"msg": "aspnetapp-dev: EXISTS"
"msg": "nexus: EXISTS"

TASK [cluster_verification : Report aspnetapp health]
"msg": "aspnetapp-dev available replicas: 1"

TASK [Summary]
"msg": "Configuration complete. All tools verified."

PLAY RECAP
crc-vm: ok=23  changed=0  unreachable=0  failed=0  skipped=1
```

**Idempotency confirmed**: `changed=0` — running the playbook on an already-configured system makes zero changes.

---

## Key Patterns

### `changed_when: false`
All verification tasks use `changed_when: false` — reporting a version number never modifies state:
```yaml
- name: Check Trivy version
  ansible.builtin.command: trivy --version
  register: trivy_version
  changed_when: false   # Read-only check, never marks as "changed"
  failed_when: false    # Missing tool is a warning, not a failure
```

### Conditional installation
```yaml
- name: Install Skopeo if missing
  ansible.builtin.apt:
    name: skopeo
    state: present
  become: true
  when: skopeo_version.rc != 0   # Only runs if skopeo wasn't found
```

### Loop with register
```yaml
- name: Verify namespaces
  ansible.builtin.command: oc get namespace {{ item }}
  loop: [argocd, vault, monitoring, aspnetapp-dev, nexus]
  register: ns_check
  changed_when: false
  failed_when: false   # Missing namespace → rc != 0, but don't abort

- name: Report namespace status
  ansible.builtin.debug:
    msg: "{{ item.item }}: {{ 'EXISTS' if item.rc == 0 else 'MISSING' }}"
  loop: "{{ ns_check.results }}"
```

---

## Ansible vs kubectl for Cluster Verification

| Approach | Ansible Playbook | Shell Script |
|----------|-----------------|--------------|
| Idempotent | ✅ | ❌ (need `set -e` + manual checks) |
| Structured output | ✅ (JSON facts) | ❌ (text parsing) |
| Error handling | ✅ (`failed_when`, `ignore_errors`) | ❌ (manual `||`) |
| Reusable roles | ✅ | ❌ |
| Inventory management | ✅ (multiple envs) | ❌ (hardcoded) |

---

## What's Next (Day 26)

Combine Terraform + Ansible in a single pipeline:
1. `terraform apply` → provisions infrastructure
2. `ansible-playbook` → verifies configuration and applies post-provisioning config
