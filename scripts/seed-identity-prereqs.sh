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

need_value() {
  local variable_name="$1"

  if [[ -z "${!variable_name}" ]]; then
    echo "${variable_name} cannot be empty" >&2
    exit 1
  fi
}

vault_path_exists() {
  local secret_path="$1"
  local error_output

  if error_output=$(
    printf '%s\n' "$ROOT_TOKEN" | \
      kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
        sh -ec '
          IFS= read -r VAULT_TOKEN
          export VAULT_TOKEN
          exec vault kv get -mount=kv "$1"
        ' sh "$secret_path" 2>&1 >/dev/null
  ); then
    return 0
  fi

  if [[ "$error_output" == *"No value found"* ]]; then
    return 1
  fi

  echo "could not check kv/${secret_path}:" >&2
  echo "$error_output" >&2
  exit 1
}

vault_create_json() {
  local secret_path="$1"

  {
    printf '%s\n' "$ROOT_TOKEN"
    cat
  } | kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
    sh -ec '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN
      exec vault kv put -cas=0 -mount=kv "$1" @/dev/stdin
    ' sh "$secret_path"
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
  unset AUTHENTIK_SECRET_KEY AUTHENTIK_POSTGRES_PASSWORD
  unset IMMICH_OIDC_SECRET NEXTCLOUD_OIDC_SECRET HEADSCALE_OIDC_SECRET
  unset AUTHENTIK_SMTP_PASSWORD IMMICH_SMTP_PASSWORD NEXTCLOUD_SMTP_PASSWORD
  unset IMMICH_CONFIG
}

trap cleanup EXIT

read -rp "Authentik Mailgun SMTP username: " AUTHENTIK_SMTP_USERNAME
read -rsp "Authentik Mailgun SMTP password: " AUTHENTIK_SMTP_PASSWORD
printf '\n'

read -rp "Immich Mailgun SMTP username: " IMMICH_SMTP_USERNAME
read -rsp "Immich Mailgun SMTP password: " IMMICH_SMTP_PASSWORD
printf '\n'

read -rp "Nextcloud Mailgun SMTP username: " NEXTCLOUD_SMTP_USERNAME
read -rsp "Nextcloud Mailgun SMTP password: " NEXTCLOUD_SMTP_PASSWORD
printf '\n'

read -rp "Path to the complete current Immich configuration export: " IMMICH_EXPORT_FILE

for required_variable in \
  AUTHENTIK_SMTP_USERNAME \
  AUTHENTIK_SMTP_PASSWORD \
  IMMICH_SMTP_USERNAME \
  IMMICH_SMTP_PASSWORD \
  NEXTCLOUD_SMTP_USERNAME \
  NEXTCLOUD_SMTP_PASSWORD \
  IMMICH_EXPORT_FILE
do
  need_value "$required_variable"
done

[[ -f "$IMMICH_EXPORT_FILE" ]] || {
  echo "Immich configuration export not found: $IMMICH_EXPORT_FILE" >&2
  exit 1
}

jq empty "$IMMICH_EXPORT_FILE"

TARGET_PATHS=(
  apps/identity/authentik
  apps/media/immich-identity
  apps/productivity/nextcloud-identity
  apps/productivity/nextcloud-mail
  apps/other/headscale-identity
)

EXISTING_PATHS=()
for secret_path in "${TARGET_PATHS[@]}"; do
  if vault_path_exists "$secret_path"; then
    EXISTING_PATHS+=("kv/${secret_path}")
  fi
done

if ((${#EXISTING_PATHS[@]} > 0)); then
  echo "refusing to overwrite existing Vault paths:" >&2
  printf '  %s\n' "${EXISTING_PATHS[@]}" >&2
  echo "use a version-aware Vault rotation procedure for existing values" >&2
  exit 1
fi

AUTHENTIK_SECRET_KEY=$(openssl rand -hex 48)
AUTHENTIK_POSTGRES_PASSWORD=$(openssl rand -hex 32)
IMMICH_OIDC_SECRET=$(openssl rand -hex 32)
NEXTCLOUD_OIDC_SECRET=$(openssl rand -hex 32)
HEADSCALE_OIDC_SECRET=$(openssl rand -hex 32)

echo "creating kv/apps/identity/authentik"
jq -cn \
  --arg secret_key "$AUTHENTIK_SECRET_KEY" \
  --arg postgres_username "authentik" \
  --arg postgres_password "$AUTHENTIK_POSTGRES_PASSWORD" \
  --arg smtp_username "$AUTHENTIK_SMTP_USERNAME" \
  --arg smtp_password "$AUTHENTIK_SMTP_PASSWORD" \
  --arg immich_secret "$IMMICH_OIDC_SECRET" \
  --arg nextcloud_secret "$NEXTCLOUD_OIDC_SECRET" \
  --arg headscale_secret "$HEADSCALE_OIDC_SECRET" \
  '{
    "secret-key": $secret_key,
    "postgresql-username": $postgres_username,
    "postgresql-password": $postgres_password,
    "smtp-username": $smtp_username,
    "smtp-password": $smtp_password,
    "oidc-immich-client-secret": $immich_secret,
    "oidc-nextcloud-client-secret": $nextcloud_secret,
    "oidc-headscale-client-secret": $headscale_secret
  }' | vault_create_json "apps/identity/authentik"

echo "creating kv/apps/productivity/nextcloud-identity"
jq -cn \
  --arg client_id "nextcloud" \
  --arg client_secret "$NEXTCLOUD_OIDC_SECRET" \
  '{
    "client-id": $client_id,
    "client-secret": $client_secret
  }' | vault_create_json "apps/productivity/nextcloud-identity"

echo "creating kv/apps/productivity/nextcloud-mail"
jq -cn \
  --arg host "smtp.mailgun.org" \
  --arg username "$NEXTCLOUD_SMTP_USERNAME" \
  --arg password "$NEXTCLOUD_SMTP_PASSWORD" \
  '{
    "host": $host,
    "username": $username,
    "password": $password
  }' | vault_create_json "apps/productivity/nextcloud-mail"

echo "creating kv/apps/other/headscale-identity"
jq -cn \
  --arg client_id "headscale" \
  --arg client_secret "$HEADSCALE_OIDC_SECRET" \
  '{
    "client-id": $client_id,
    "client-secret": $client_secret
  }' | vault_create_json "apps/other/headscale-identity"

echo "merging identity settings into the complete Immich export"
IMMICH_CONFIG=$(
  jq -c \
    --arg smtp_username "$IMMICH_SMTP_USERNAME" \
    --arg smtp_password "$IMMICH_SMTP_PASSWORD" \
    --arg oidc_secret "$IMMICH_OIDC_SECRET" \
    '
      . * {
        "notifications": {
          "smtp": {
            "enabled": true,
            "from": "immich@mail.rcrumana.xyz",
            "replyTo": "",
            "transport": {
              "host": "smtp.mailgun.org",
              "ignoreCert": false,
              "password": $smtp_password,
              "port": 587,
              "secure": false,
              "username": $smtp_username
            }
          }
        },
        "oauth": {
          "autoLaunch": false,
          "autoRegister": true,
          "buttonText": "Sign in with Authentik",
          "clientId": "immich",
          "clientSecret": $oidc_secret,
          "defaultStorageQuota": null,
          "enabled": true,
          "issuerUrl": "https://auth.rcrumana.xyz/application/o/immich/",
          "endSessionEndpoint": "",
          "mobileOverrideEnabled": false,
          "mobileRedirectUri": "",
          "profileSigningAlgorithm": "none",
          "roleClaim": "immich_role",
          "scope": "openid email profile immich",
          "signingAlgorithm": "RS256",
          "storageLabelClaim": "preferred_username",
          "storageQuotaClaim": "immich_quota",
          "timeout": 30000,
          "tokenEndpointAuthMethod": "client_secret_post"
        },
        "passwordLogin": {
          "enabled": false
        },
        "server": {
          "externalDomain": "https://immich.rcrumana.xyz",
          "loginPageMessage": "",
          "publicUsers": false
        }
      }
    ' \
    "$IMMICH_EXPORT_FILE"
)

echo "creating kv/apps/media/immich-identity"
jq -cn \
  --arg config "$IMMICH_CONFIG" \
  '{"config.json": $config}' | \
  vault_create_json "apps/media/immich-identity"

echo
echo "identity prerequisite Vault paths created successfully"
echo "the existing shared Harbor pull credential was not changed"
