# Day 18 — HashiCorp Vault: Dev Mode, KV Engine, Kubernetes Auth

## Goals
- Deploy Vault in dev mode on OpenShift
- Configure KV v2 secrets engine
- Set up Kubernetes auth with per-namespace policies
- Understand secret lifecycle in Vault

---

## Vault Deployment on OKD

Vault in dev mode (`vault server -dev`):
- In-memory storage — **data lost on pod restart**
- Pre-initialized and unsealed
- Root token: `root`
- Perfect for learning; **never for production**

**OKD-specific issue:** Vault's Docker image startup tries `setcap cap_ipc_lock=+ep vault` (to prevent memory swapping). This requires `CAP_SETFCAP` which is blocked by OpenShift SCCs.

**Fix:** `SKIP_SETCAP=true` env var tells the entrypoint to skip the setcap step.

```yaml
env:
  - name: SKIP_SETCAP
    value: "true"
  - name: VAULT_DEV_ROOT_TOKEN_ID
    value: "root"                   # ← never do this in prod
  - name: VAULT_DEV_LISTEN_ADDRESS
    value: "0.0.0.0:8200"
```

**Access:** Route TLS terminates at the OpenShift router, but Vault is running HTTP internally. Use `oc port-forward` to access the Vault CLI from the VM.

---

## KV v2 Secrets Engine

Vault KV v2 supports **secret versioning** — every write creates a new version, old versions are retained.

```bash
export VAULT_ADDR="http://127.0.0.1:8200"   # via port-forward
export VAULT_TOKEN="root"

# Enable KV v2 at path "secret/"
vault secrets enable -path=secret kv-v2

# Write secrets (environment-separated paths)
vault kv put secret/aspnetapp/dev \
  db_password="dev-secret-abc123" \
  api_key="dev-api-key-xyz789" \
  connection_string="Server=dev-db;Database=aspnetapp"

vault kv put secret/aspnetapp/prod \
  db_password="prod-VERY-SECURE-password-1234!" \
  api_key="prod-api-key-SECURE-abc" \
  connection_string="Server=prod-db.internal;Database=aspnetapp"

# Read
vault kv get secret/aspnetapp/dev

# List versions
vault kv metadata get secret/aspnetapp/dev
```

**Path hierarchy:** `secret/aspnetapp/{env}` separates dev/prod secrets with different policies.

---

## Kubernetes Auth Method

Pods authenticate to Vault using their Kubernetes Service Account token.

### How it works:
```
Pod (with SA token)
  └── POST /v1/auth/kubernetes/login
        └── Vault validates token with K8s TokenReview API
              └── Returns Vault token (short-lived) with policy
```

### Configuration:

```bash
# Enable Kubernetes auth
vault auth enable kubernetes

# Configure with cluster details
vault write auth/kubernetes/config \
  kubernetes_host="https://api.crc.testing:6443" \
  kubernetes_ca_cert="$(oc get configmap kube-root-ca.crt -n kube-system \
    -o jsonpath='{.data.ca\.crt}')" \
  disable_iss_validation=true

# Create policy (fine-grained access control)
vault policy write aspnetapp-dev - <<EOF
path "secret/data/aspnetapp/dev" {
  capabilities = ["read"]
}
EOF

# Create role (binds SA + namespace → policy)
vault write auth/kubernetes/role/aspnetapp-dev \
  bound_service_account_names=aspnetapp-sa \
  bound_service_account_namespaces=aspnetapp-dev \
  policies=aspnetapp-dev \
  ttl=1h
```

### Roles created:

| Role | SA | Namespace | Policy |
|------|----|-----------|--------|
| aspnetapp-dev | aspnetapp-sa | aspnetapp-dev | Read dev secrets only |
| aspnetapp-prod | aspnetapp-sa | aspnetapp-prod | Read prod secrets only |

**Security principle:** The `aspnetapp-sa` in `aspnetapp-dev` cannot read `aspnetapp-prod` secrets even with the same service account name, because the Kubernetes namespace is part of the role binding.

---

## Vault vs Kubernetes Secrets

| Feature | Kubernetes Secret | Vault |
|---------|-------------------|-------|
| Encryption at rest | Optional (needs EncryptionConfig) | Always (AES-256-GCM) |
| Secret rotation | Manual re-create | Built-in versioning + lease TTL |
| Dynamic secrets | ❌ | ✅ (database, cloud, PKI) |
| Access audit log | K8s audit log | Vault audit log |
| Fine-grained RBAC | K8s RBAC | Vault policies |
| Secret sprawl | High (many objects) | Centralized |

---

## Vault in Dev Mode Limitations

| Feature | Dev Mode | Production Mode |
|---------|----------|-----------------|
| Storage | In-memory | Consul, etcd, S3, Raft |
| Seal/Unseal | Never sealed | Shamir key shares or Auto-unseal |
| Data persistence | Lost on restart | Persisted to backend |
| HA | No | Yes (with integrated Raft) |
| Use case | Learning/testing | Production |

For production on OpenShift, use the **Vault Helm chart** with integrated Raft storage and auto-unseal via Cloud KMS or Transit secret engine.
