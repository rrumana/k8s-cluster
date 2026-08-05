#!/usr/bin/env bash
set -euo pipefail

VAULT_INIT_FILE=${VAULT_INIT_FILE:-${PWD}/vault-init.json}
VAULT_NAMESPACE=${VAULT_NAMESPACE:-security}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need_cmd jq
need_cmd kubectl
need_cmd openssl

[[ -f "$VAULT_INIT_FILE" ]] || {
  echo "missing Vault initialization file: $VAULT_INIT_FILE" >&2
  exit 1
}

VAULT_POD=$(
  kubectl -n "$VAULT_NAMESPACE" get pods \
    -l app.kubernetes.io/name=vault \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}'
)

[[ -n "$VAULT_POD" ]] || {
  echo "no running Vault pod found in namespace $VAULT_NAMESPACE" >&2
  exit 1
}

ROOT_TOKEN=$(jq -er '.root_token' "$VAULT_INIT_FILE")
OIDC_CLIENT_SECRET=$(openssl rand -hex 32)

cleanup() {
  unset ROOT_TOKEN OIDC_CLIENT_SECRET
}

trap cleanup EXIT

vault_has_property() {
  local secret_path=$1
  local secret_property=$2

  {
    printf '%s\n' "$ROOT_TOKEN"
  } | kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
    sh -ec '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN
      exec vault kv get -field="$2" -mount=kv "$1"
    ' sh "$secret_path" "$secret_property" >/dev/null 2>&1
}

vault_add_property() {
  local secret_path=$1
  local secret_property=$2
  local secret_value=$3

  if vault_has_property "$secret_path" "$secret_property"; then
    echo "kv/${secret_path} already contains ${secret_property}; retaining it"
    return
  fi

  echo "adding ${secret_property} to kv/${secret_path}"
  {
    printf '%s\n' "$ROOT_TOKEN"
    jq -cn \
      --arg property "$secret_property" \
      --arg value "$secret_value" \
      '{($property): $value}'
  } | kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
    sh -ec '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN
      if vault kv get -mount=kv "$1" >/dev/null 2>&1; then
        exec vault kv patch -mount=kv "$1" @/dev/stdin
      fi
      exec vault kv put -cas=0 -mount=kv "$1" @/dev/stdin
    ' sh "$secret_path"

  vault_has_property "$secret_path" "$secret_property"
}

vault_add_property \
  apps/identity/authentik \
  oidc-vaultwarden-client-secret \
  "$OIDC_CLIENT_SECRET"

vault_add_property \
  apps/productivity/vaultwarden-identity \
  client-secret \
  "$OIDC_CLIENT_SECRET"

echo "Vaultwarden identity prerequisite created successfully"
