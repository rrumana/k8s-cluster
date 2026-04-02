# Vault Operations Runbook

This is the canonical operational guide for Vault in this cluster.

## Why Vault Exists

Vault exists to solve a specific problem: avoiding an in-repo secrets folder full of sensitive values.

Without Vault, secrets usually end up in one of these bad places:

- Plaintext in Git
- Encrypted blobs that still need key handling in Git
- Hand-created Kubernetes Secrets with poor rotation discipline

With this setup:

- Vault is the source of truth for runtime secrets
- External Secrets Operator (ESO) syncs Vault values into Kubernetes Secrets
- Apps consume Kubernetes Secrets, but secret authority stays centralized

## Cluster Context

- Namespace: `security`
- Vault pods: `vault-0`, `vault-1`, `vault-2`
- Storage: Raft integrated storage on Ceph-backed PVCs
- ESO store: `ClusterSecretStore/vault`
- Vault path model used by ESO: KV v2 under `kv/`

## Preconditions

```bash
kubectl get nodes
kubectl -n security get pods -l app.kubernetes.io/name=vault -o wide
jq --version
openssl version
```

Expected:

- All three Vault pods are running
- You have `~/vault-init.json` from original `vault operator init`

## Sanity Checks

### 1) Check pod and seal state

```bash
kubectl -n security get pods -o wide

for p in vault-0 vault-1 vault-2; do
  echo "=== $p ==="
  kubectl -n security exec "$p" -- vault status
  echo
done
```

Expected:

- `Initialized: true`
- `Sealed: false`
- One active leader, remaining followers/standby

### 2) Check Raft membership

```bash
ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && vault operator raft list-peers"
unset ROOT_TOKEN
```

### 3) Check ESO can talk to Vault

```bash
kubectl get clustersecretstore vault -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
kubectl -n security get pods -l app.kubernetes.io/name=external-secrets
```

## Unseal And Recovery Procedure

Run after full-cluster restart or any event where Vault becomes sealed.

```bash
# 0) Preconditions:
# - ~/vault-init.json exists from a successful `vault operator init`
# - vault-0/1/2 pods are running in namespace security

# 1) Load keys + root token from init file
KEY1=$(jq -r '.unseal_keys_b64[0]' ~/vault-init.json)
KEY2=$(jq -r '.unseal_keys_b64[1]' ~/vault-init.json)
ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)

# 2) Unseal vault-0 (active/bootstrap node)
kubectl -n security exec vault-0 -- vault operator unseal "$KEY1"
kubectl -n security exec vault-0 -- vault operator unseal "$KEY2"

# 3) Join followers to raft (safe to run every time; may say already joined)
kubectl -n security exec vault-1 -- vault operator raft join http://vault-0.vault-internal:8200 || true
kubectl -n security exec vault-2 -- vault operator raft join http://vault-0.vault-internal:8200 || true

# 4) Unseal followers
kubectl -n security exec vault-1 -- vault operator unseal "$KEY1"
kubectl -n security exec vault-1 -- vault operator unseal "$KEY2"
kubectl -n security exec vault-2 -- vault operator unseal "$KEY1"
kubectl -n security exec vault-2 -- vault operator unseal "$KEY2"

# 5) Verify all nodes are unsealed
for p in vault-0 vault-1 vault-2; do
  echo "=== $p ==="
  kubectl -n security exec "$p" -- vault status
done

# 6) Verify raft membership (requires login)
kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && vault operator raft list-peers"

# 7) Cleanup shell variables
unset KEY1 KEY2 ROOT_TOKEN
```

If any pod says Vault is not initialized, re-run step 3 for that pod, then step 4 for that pod.

## Common Operations

Replace the example paths and object names below with the secret you are
actually rotating. The examples use objects that exist in the current repo.

### Read a Vault value (example)

```bash
ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
SECRET_PATH="kv/apps/productivity/nextcloud-admin"
PROPERTY="nextcloud-password"

kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && vault kv get -field='$PROPERTY' '$SECRET_PATH'"
unset ROOT_TOKEN
unset SECRET_PATH PROPERTY
```

### Write/update a Vault value (example)

```bash
ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
SECRET_PATH="kv/apps/productivity/nextcloud-admin"
PROPERTY="nextcloud-password"
NEW_PASS=$(openssl rand -base64 32 | tr -d '\n')

kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && \
  vault kv patch '$SECRET_PATH' '$PROPERTY'='$NEW_PASS'"

unset ROOT_TOKEN SECRET_PATH PROPERTY NEW_PASS
```

### Force ESO refresh for one secret

```bash
NAMESPACE="web"
SECRET_NAME="harbor-pull-creds"

kubectl -n "$NAMESPACE" delete secret "$SECRET_NAME"
kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -w
# Ctrl+C after it reappears

unset NAMESPACE SECRET_NAME
```

### Inspect ExternalSecret status

```bash
NAMESPACE="web"
SECRET_NAME="harbor-pull-creds"

kubectl -n "$NAMESPACE" get externalsecret "$SECRET_NAME" \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}'

unset NAMESPACE SECRET_NAME
```

## Emergency Operations

### Seal a node intentionally

```bash
kubectl -n security exec vault-0 -- vault operator seal
```

### Restart Vault StatefulSet

```bash
kubectl -n security rollout restart statefulset/vault
kubectl -n security rollout status statefulset/vault --timeout=300s
```

Then run the full unseal procedure.

## Troubleshooting

### Vault command returns permission errors

- Check root token source (`~/vault-init.json`)
- Re-run login inside `vault-0` pod and retry command

### Secret does not appear in app namespace

1. Check ExternalSecret conditions.
2. Confirm Vault path and property names match manifest.
3. Confirm `ClusterSecretStore/vault` is `Ready=True`.
4. Delete target Kubernetes Secret to force quick ESO reconcile.

### Vault pods are up but still sealed after restart

- Run full unseal flow for all three pods.
- Verify Raft peers from `vault-0`.

### Follower unseal fails with `no expected answer for the server id provided`

This indicates the follower's Raft join/bootstrap handshake is out of sync with
the active node. It commonly happens after repeated `raft join` / `unseal`
attempts or after a follower loses local state during a node disruption.

Recommended recovery order:

1. Verify `vault-0` is active and at least one other node is healthy.
2. Check peers from `vault-0`:

   ```bash
   ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
   kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && vault operator raft list-peers"
   unset ROOT_TOKEN
   ```

3. If the broken follower appears as a stale or duplicate peer, remove that
   peer from `vault-0`.

   ```bash
   ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)

   # Example: remove stale peer "vault-1" from the active node.
   kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && vault operator raft remove-peer vault-1"

   # Confirm the stale peer is gone.
   kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && vault operator raft list-peers"

   unset ROOT_TOKEN
   ```

   The `remove-peer` argument must be the Raft server ID from `vault operator
   raft list-peers` output, not the pod IP.

4. If you removed the peer and want that same pod ordinal back in the cluster,
   clear its old Raft data before rejoining it.

   ```bash
   # Confirm which PVC belongs to the broken follower.
   kubectl -n security get pvc | grep vault-1

   # Remove the pod and its data PVC for that follower only.
   kubectl -n security delete pod vault-1 --wait=true
   kubectl -n security delete pvc data-vault-1

   # Wait for StatefulSet to recreate the pod.
   kubectl -n security get pod vault-1 -w
   ```

   Only do this when the remaining nodes still have quorum.

5. Re-run `raft join` on the rebuilt follower once.

   ```bash
   kubectl -n security exec vault-1 -- vault operator raft join http://vault-0.vault-internal:8200
   ```

6. Immediately provide the two unseal keys again to that same follower.

   ```bash
   KEY1=$(jq -r '.unseal_keys_b64[0]' ~/vault-init.json)
   KEY2=$(jq -r '.unseal_keys_b64[1]' ~/vault-init.json)

   kubectl -n security exec vault-1 -- vault operator unseal "$KEY1"
   kubectl -n security exec vault-1 -- vault operator unseal "$KEY2"

   unset KEY1 KEY2
   ```

If the follower still reports `Vault is not initialized` after this sequence,
repeat the peer list check from `vault-0` before issuing another `raft join`.
Do not loop `raft join` / `unseal` blindly; each attempt can create a new
bootstrap challenge on the leader.
