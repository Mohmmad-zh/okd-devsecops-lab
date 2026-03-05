# Day 19 — Vault + Kubernetes Integration (Secret Injection)

## Goals
- Pods authenticate to Vault using Kubernetes Service Account tokens
- Secrets fetched at runtime via init container pattern
- Secrets passed via memory-backed emptyDir volume (never written to disk)
- Zero Kubernetes Secret objects used

---

## Authentication Flow

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Pod starts with Kubernetes SA token (auto-mounted)       │
│ 2. Init container POSTs token to Vault K8s auth endpoint   │
│ 3. Vault validates token via K8s TokenReview API            │
│ 4. If SA name + namespace match role → Vault token issued   │
│ 5. Init container reads secrets using Vault token           │
│ 6. Secrets written to memory-backed shared volume           │
│ 7. App container sources secrets from that volume           │
└─────────────────────────────────────────────────────────────┘
```

---

## Vault Kubernetes Login (HTTP API)

```bash
# Inside pod (using pod's own SA JWT)
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

AUTH=$(wget -qO- \
  --header "Content-Type: application/json" \
  --post-data "{\"role\":\"vault-demo\",\"jwt\":\"$JWT\"}" \
  http://vault.vault.svc.cluster.local:8200/v1/auth/kubernetes/login)

VAULT_TOKEN=$(echo "$AUTH" | sed 's/.*"client_token":"\([^"]*\)".*/\1/')
```

---

## Reading Secrets (HTTP API)

```bash
SECRET=$(wget -qO- \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  http://vault.vault.svc.cluster.local:8200/v1/secret/data/aspnetapp/dev)

# JSON response:
# {"data":{"data":{"db_password":"...","api_key":"...","connection_string":"..."}}}
```

---

## Init Container Pattern (implemented)

```yaml
initContainers:
  - name: vault-init
    image: hashicorp/vault:1.18.3
    env:
      - name: SKIP_SETCAP        # Required on OKD (no CAP_SETFCAP)
        value: "true"
    command: [sh, -c]
    args:
      - |
        JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
        TOKEN=$(wget ... | sed extract client_token)
        SECRET=$(wget --header "X-Vault-Token: $TOKEN" .../v1/secret/data/...)
        printf "DB_PASSWORD=%s\nAPI_KEY=%s\n" ... > /vault-secrets/config.env
    volumeMounts:
      - name: vault-secrets
        mountPath: /vault-secrets

containers:
  - name: app
    command: [sh, -c, ". /vault-secrets/config.env && run_app"]
    volumeMounts:
      - name: vault-secrets
        mountPath: /vault-secrets
        readOnly: true              # ← read only in app container

volumes:
  - name: vault-secrets
    emptyDir:
      medium: Memory               # ← stored in RAM, not disk
```

---

## Demo Results

```
=== Vault init container ===
Authenticated! Policies: aspnetapp-dev
Secrets written: DB_PASSWORD API_KEY CONNECTION_STRING

=== App container ===
DB_PASSWORD set: YES, length=17
API_KEY set: YES
CONNECTION_STRING: Server=dev-db;Database=aspnetapp

SUCCESS: App running with Vault-managed secrets
Zero Kubernetes Secrets used. No secrets in YAML manifests.
```

---

## Key Security Properties

| Property | Kubernetes Secrets | Vault init-container |
|----------|-------------------|---------------------|
| Secret at rest encrypted | Optional | Always (Vault AES-256) |
| Secret visible in `oc get secret` | YES (base64) | NO |
| Secret in YAML manifests | YES | NO |
| Audit log of secret access | K8s audit log | Vault audit log (more detailed) |
| Secret rotation | Manual restart | Vault lease renewal |
| Short-lived secret access | NO | YES (TTL=1h) |
| Memory-only in pod | NO | YES (emptyDir Memory) |

---

## Vault Policy That Was Needed

Initial policy was too restrictive — `vault kv get` CLI requires `sys/internal/ui/mounts/*` for metadata lookup. Fixed by:

```hcl
path "secret/data/aspnetapp/dev" {
  capabilities = ["read"]
}
path "secret/metadata/aspnetapp/dev" {
  capabilities = ["read"]
}
path "sys/internal/ui/mounts/*" {
  capabilities = ["read"]
}
```

**Learning:** When using the `vault kv` CLI, it makes extra API calls beyond the raw data endpoint. For tightly controlled policies, use the raw Vault HTTP API instead of the CLI.

---

## Production Upgrade Path

For production, use the **Vault Agent Injector** (requires Helm chart deployment):

```yaml
# Pod annotations trigger automatic sidecar injection
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "aspnetapp-prod"
  vault.hashicorp.com/agent-inject-secret-config.env: "secret/data/aspnetapp/prod"
  vault.hashicorp.com/agent-inject-template-config.env: |
    {{- with secret "secret/data/aspnetapp/prod" -}}
    DB_PASSWORD={{ .Data.data.db_password }}
    API_KEY={{ .Data.data.api_key }}
    {{- end }}
```

The injector adds `vault-agent-init` and `vault-agent` sidecar automatically — no custom init container needed.
