#!/usr/bin/env bash
set -euo pipefail

VAULT_INIT_FILE=${VAULT_INIT_FILE:-${PWD}/vault-init.json}
VAULT_NAMESPACE=${VAULT_NAMESPACE:-security}
SECRET_PATH=apps/productivity/vaultwarden-access

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

vault_path_exists() {
  local error_output

  if error_output=$(
    printf '%s\n' "$ROOT_TOKEN" | \
      kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
        sh -ec '
          IFS= read -r VAULT_TOKEN
          export VAULT_TOKEN
          exec vault kv get -mount=kv "$1"
        ' sh "$SECRET_PATH" 2>&1 >/dev/null
  ); then
    return 0
  fi

  if [[ "$error_output" == *"No value found"* ]]; then
    return 1
  fi

  echo "could not check kv/${SECRET_PATH}:" >&2
  echo "$error_output" >&2
  exit 1
}

vault_create_json() {
  {
    printf '%s\n' "$ROOT_TOKEN"
    jq -cn \
      --arg admin_token "$ADMIN_TOKEN_HASH" \
      --arg smtp_username "$SMTP_USERNAME" \
      --arg smtp_password "$SMTP_PASSWORD" \
      '{
        "admin-token": $admin_token,
        "smtp-username": $smtp_username,
        "smtp-password": $smtp_password
      }'
  } | kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
    sh -ec '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN
      exec vault kv put -cas=0 -mount=kv "$1" @/dev/stdin
    ' sh "$SECRET_PATH"
}

vault_has_property() {
  local secret_property=$1

  printf '%s\n' "$ROOT_TOKEN" | \
    kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
      sh -ec '
        IFS= read -r VAULT_TOKEN
        export VAULT_TOKEN
        exec vault kv get -field="$2" -mount=kv "$1"
      ' sh "$SECRET_PATH" "$secret_property" >/dev/null
}

cleanup() {
  unset ROOT_TOKEN ADMIN_PASSWORD ADMIN_PASSWORD_REPEAT ADMIN_TOKEN_HASH
  unset SMTP_USERNAME SMTP_PASSWORD ARGON2_SALT
}

trap cleanup EXIT

need_cmd argon2
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

if vault_path_exists; then
  echo "kv/${SECRET_PATH} already exists; refusing to overwrite or rotate it" >&2
  exit 1
fi

read -rp "Vaultwarden Mailgun SMTP username: " SMTP_USERNAME
read -rsp "Vaultwarden Mailgun SMTP password: " SMTP_PASSWORD
printf '\n'
read -rsp "Vaultwarden administrator password (minimum 20 characters): " ADMIN_PASSWORD
printf '\n'
read -rsp "Repeat Vaultwarden administrator password: " ADMIN_PASSWORD_REPEAT
printf '\n'

[[ -n "$SMTP_USERNAME" ]] || {
  echo "Vaultwarden Mailgun SMTP username cannot be empty" >&2
  exit 1
}
[[ -n "$SMTP_PASSWORD" ]] || {
  echo "Vaultwarden Mailgun SMTP password cannot be empty" >&2
  exit 1
}
[[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_REPEAT" ]] || {
  echo "Vaultwarden administrator passwords do not match" >&2
  exit 1
}
(( ${#ADMIN_PASSWORD} >= 20 )) || {
  echo "Vaultwarden administrator password must contain at least 20 characters" >&2
  exit 1
}

ARGON2_SALT=$(openssl rand -base64 32 | tr -d '\n')
ADMIN_TOKEN_HASH=$(
  printf '%s' "$ADMIN_PASSWORD" | \
    argon2 "$ARGON2_SALT" -e -id -k 65540 -t 3 -p 4
)

[[ "$ADMIN_TOKEN_HASH" == '$argon2id$'* ]] || {
  echo "argon2 did not return a valid Argon2id PHC string" >&2
  exit 1
}

echo "creating kv/${SECRET_PATH}"
vault_create_json

vault_has_property admin-token
vault_has_property smtp-username
vault_has_property smtp-password

echo "Vaultwarden administrator and Mailgun prerequisites created successfully"
echo "the administrator password and generated Argon2id hash were not printed"
