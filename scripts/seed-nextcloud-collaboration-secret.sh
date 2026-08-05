#!/usr/bin/env bash
set -euo pipefail

VAULT_INIT_FILE=${VAULT_INIT_FILE:-${PWD}/vault-init.json}
VAULT_NAMESPACE=${VAULT_NAMESPACE:-security}
VAULT_SECRET_PATH=apps/productivity/nextcloud-identity
VAULT_SECRET_PROPERTY=whiteboard-jwt-secret

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
WHITEBOARD_JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')

cleanup() {
  unset ROOT_TOKEN WHITEBOARD_JWT_SECRET
}

trap cleanup EXIT

if {
  printf '%s\n' "$ROOT_TOKEN"
} | kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
  sh -ec '
    IFS= read -r VAULT_TOKEN
    export VAULT_TOKEN
    exec vault kv get -field="$2" -mount=kv "$1"
  ' sh "$VAULT_SECRET_PATH" "$VAULT_SECRET_PROPERTY" >/dev/null 2>&1
then
  echo "kv/${VAULT_SECRET_PATH} already contains ${VAULT_SECRET_PROPERTY}; refusing to rotate it" >&2
  exit 1
fi

echo "adding ${VAULT_SECRET_PROPERTY} to kv/${VAULT_SECRET_PATH}"
{
  printf '%s\n' "$ROOT_TOKEN"
  jq -cn \
    --arg property "$VAULT_SECRET_PROPERTY" \
    --arg value "$WHITEBOARD_JWT_SECRET" \
    '{($property): $value}'
} | kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
  sh -ec '
    IFS= read -r VAULT_TOKEN
    export VAULT_TOKEN
    exec vault kv patch -mount=kv "$1" @/dev/stdin
  ' sh "$VAULT_SECRET_PATH"

{
  printf '%s\n' "$ROOT_TOKEN"
} | kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
  sh -ec '
    IFS= read -r VAULT_TOKEN
    export VAULT_TOKEN
    exec vault kv get -field="$2" -mount=kv "$1"
  ' sh "$VAULT_SECRET_PATH" "$VAULT_SECRET_PROPERTY" >/dev/null

echo "Nextcloud collaboration JWT prerequisite created successfully"
