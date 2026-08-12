#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VAULT_INIT_FILE=${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}
VAULT_NAMESPACE=${VAULT_NAMESPACE:-security}
HARBOR_HOST=${HARBOR_HOST:-harbor.rcrumana.xyz}
HARBOR_USERNAME=${HARBOR_USERNAME:-admin}
: "${HARBOR_PASSWORD:?Set HARBOR_PASSWORD to a Harbor account allowed to push thirdparty-charts and mirror}"

HARBOR_CHARTS_REPO="oci://${HARBOR_HOST}/thirdparty-charts"
SECRET_PATH=apps/databases/qdrant-api-keys

# renovate: datasource=helm depName=qdrant versioning=helm registryUrl=https://qdrant.github.io/qdrant-helm
QDRANT_CHART_VERSION="1.18.2"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

vault_path_exists() {
  local error_output

  # shellcheck disable=SC2016
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

create_qdrant_keys() {
  local api_key
  local read_only_api_key

  api_key=$(openssl rand -hex 32)
  read_only_api_key=$(openssl rand -hex 32)

  echo "creating kv/${SECRET_PATH}"
  # shellcheck disable=SC2016
  {
    printf '%s\n' "$ROOT_TOKEN"
    jq -cn \
      --arg api_key "$api_key" \
      --arg read_only_api_key "$read_only_api_key" \
      '{"api-key": $api_key, "read-only-api-key": $read_only_api_key}'
  } | kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
    sh -ec '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN
      exec vault kv put -cas=0 -mount=kv "$1" @/dev/stdin
    ' sh "$SECRET_PATH"

  unset api_key read_only_api_key
}

vault_has_property() {
  local secret_property=$1

  # shellcheck disable=SC2016
  printf '%s\n' "$ROOT_TOKEN" | \
    kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
      sh -ec '
        IFS= read -r VAULT_TOKEN
        export VAULT_TOKEN
        exec vault kv get -field="$2" -mount=kv "$1"
      ' sh "$SECRET_PATH" "$secret_property" >/dev/null
}

mirror_image() {
  local source_image=$1
  local destination_image=$2
  local source_digest
  local destination_digest

  echo "  ${source_image} -> ${destination_image}"
  source_digest=$(crane digest "$source_image")
  crane copy "$source_image" "$destination_image"
  destination_digest=$(crane digest "$destination_image")
  if [[ "$destination_digest" != "$source_digest" ]]; then
    echo "digest verification failed for ${destination_image}: expected ${source_digest}, got ${destination_digest}" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n ${work_dir:-} && -d $work_dir ]]; then
    rm -rf -- "$work_dir"
  fi
  unset ROOT_TOKEN HARBOR_PASSWORD
}

trap cleanup EXIT

need_cmd crane
need_cmd helm
need_cmd jq
need_cmd kubectl
need_cmd mktemp
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
  echo "kv/${SECRET_PATH} already exists; retaining its API keys"
else
  create_qdrant_keys
fi
vault_has_property api-key
vault_has_property read-only-api-key

helm registry login "$HARBOR_HOST" \
  --username "$HARBOR_USERNAME" \
  --password-stdin <<<"$HARBOR_PASSWORD"
crane auth login "$HARBOR_HOST" \
  --username "$HARBOR_USERNAME" \
  --password-stdin <<<"$HARBOR_PASSWORD"

work_dir=$(mktemp -d)
helm pull qdrant \
  --repo https://qdrant.github.io/qdrant-helm \
  --version "$QDRANT_CHART_VERSION" \
  --destination "$work_dir"
helm push "${work_dir}/qdrant-${QDRANT_CHART_VERSION}.tgz" "$HARBOR_CHARTS_REPO"

source_images=(
  "docker.io/qdrant/qdrant:v1.18.2-unprivileged@sha256:b79aaa49ce7a7e5b7e9cf3fe76be400c911457084b4b7af47487c1c9ae5962e5"
  "registry.suse.com/bci/bci-base:16.1@sha256:a59a0a6130e137e06f40d01109e30cc5ddba2f9c046d337d1e566c552a84c8ea"
)
destination_repositories=(
  "${HARBOR_HOST}/mirror/qdrant/qdrant"
  "${HARBOR_HOST}/mirror/suse-bci/bci-base"
)

echo "Mirroring pinned Qdrant prerequisites"
for image_index in "${!source_images[@]}"; do
  source_without_digest=${source_images[$image_index]%%@*}
  source_tag=${source_without_digest##*:}
  mirror_image \
    "${source_images[$image_index]}" \
    "${destination_repositories[$image_index]}:${source_tag}"
done

echo
echo "Qdrant prerequisites seeded successfully:"
echo "  Vault path: kv/${SECRET_PATH}"
echo "  Chart: ${HARBOR_CHARTS_REPO}/qdrant:${QDRANT_CHART_VERSION}"
echo "  Images: ${#source_images[@]} pinned multi-platform manifests"
