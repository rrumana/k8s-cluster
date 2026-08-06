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

cleanup() {
  unset ROOT_TOKEN
}

trap cleanup EXIT

vault_read_property() {
  local secret_path=$1
  local secret_property=$2

  {
    printf '%s\n' "$ROOT_TOKEN"
  } | kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
    sh -ec '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN
      exec vault kv get -field="$2" -mount=kv "$1"
    ' sh "$secret_path" "$secret_property"
}

vault_write_property() {
  local secret_path=$1
  local secret_property=$2
  local secret_value=$3

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
}

ensure_matching_pair() {
  local first_path=$1
  local first_property=$2
  local second_path=$3
  local second_property=$4
  local first_value=""
  local second_value=""
  local generated_value=""
  local first_exists=false
  local second_exists=false

  if first_value=$(vault_read_property "$first_path" "$first_property" 2>/dev/null); then
    first_exists=true
  fi
  if second_value=$(vault_read_property "$second_path" "$second_property" 2>/dev/null); then
    second_exists=true
  fi

  if [[ "$first_exists" == true && "$second_exists" == true ]]; then
    if [[ "$first_value" != "$second_value" ]]; then
      echo "existing values for ${first_property} and ${second_property} do not match; refusing to overwrite either" >&2
      exit 1
    fi
    echo "kv/${first_path} and kv/${second_path} already contain a matching client secret; retaining it"
  elif [[ "$first_exists" == true ]]; then
    vault_write_property "$second_path" "$second_property" "$first_value"
  elif [[ "$second_exists" == true ]]; then
    vault_write_property "$first_path" "$first_property" "$second_value"
  else
    generated_value=$(openssl rand -hex 32)
    vault_write_property "$first_path" "$first_property" "$generated_value"
    vault_write_property "$second_path" "$second_property" "$generated_value"
  fi

  unset first_value second_value generated_value
}

ensure_matching_pair \
  apps/identity/authentik \
  oidc-jellyfin-client-secret \
  apps/media/jellyfin-identity \
  client-secret

echo "Jellyfin identity prerequisite created successfully"
