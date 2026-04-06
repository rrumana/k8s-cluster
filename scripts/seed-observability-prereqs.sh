#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HARBOR_HOST=${HARBOR_HOST:-harbor.rcrumana.xyz}
HARBOR_CHARTS_REPO="oci://${HARBOR_HOST}/thirdparty-charts"
HARBOR_MIRROR_PREFIX="${HARBOR_HOST}/mirror"
KPS_CHART_VERSION="80.13.3"
OPENSEARCH_OPERATOR_CHART_VERSION="2.8.0"
KPS_VALUES_FILE=${KPS_VALUES_FILE:-${REPO_ROOT}/cluster/platform/observability/monitoring/values.yaml}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

generate_opensearch_password_hash() {
  local password="$1"

  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -bnBC 12 "" "$password" | tr -d ':\n'
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    docker run --rm \
      --entrypoint /usr/share/opensearch/plugins/opensearch-security/tools/hash.sh \
      docker.io/opensearchproject/opensearch:3.4.0 \
      -p "$password" | tail -n1
    return
  fi

  if command -v podman >/dev/null 2>&1; then
    podman run --rm \
      --entrypoint /usr/share/opensearch/plugins/opensearch-security/tools/hash.sh \
      docker.io/opensearchproject/opensearch:3.4.0 \
      -p "$password" | tail -n1
    return
  fi

  echo "missing required command to generate OpenSearch password hash: install htpasswd or use docker/podman" >&2
  exit 1
}

mirror_image() {
  local src="$1"
  local dst="$2"

  if command -v crane >/dev/null 2>&1; then
    crane copy "$src" "$dst"
    return
  fi

  if command -v skopeo >/dev/null 2>&1; then
    skopeo copy --all "docker://${src}" "docker://${dst}"
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    docker pull "$src"
    docker tag "$src" "$dst"
    docker push "$dst"
    return
  fi

  if command -v podman >/dev/null 2>&1; then
    podman pull "$src"
    podman tag "$src" "$dst"
    podman push "$dst"
    return
  fi

  echo "need one of: crane, skopeo, docker, podman" >&2
  exit 1
}

strip_registry() {
  local image="$1"
  local first="${image%%/*}"

  if [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
    echo "${image#*/}"
  else
    echo "$image"
  fi
}

need_cmd kubectl
need_cmd jq
need_cmd openssl
need_cmd helm
need_cmd mktemp
need_cmd sed
need_cmd sort
need_cmd tr

ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
HARBOR_ADMIN_PASSWORD=$(
  kubectl -n security exec vault-0 -- sh -ec \
    "vault login '$ROOT_TOKEN' >/dev/null && vault kv get -field=HARBOR_ADMIN_PASSWORD kv/apps/harbor/core"
)
OPENSEARCH_ADMIN_PASSWORD=$(openssl rand -hex 32)
OPENSEARCH_ADMIN_PASSWORD_HASH=$(generate_opensearch_password_hash "$OPENSEARCH_ADMIN_PASSWORD")

echo "Seeding kv/apps/search/opensearch-admin in Vault"
kubectl -n security exec vault-0 -- sh -ec \
  "vault login '$ROOT_TOKEN' >/dev/null && \
   if vault kv get kv/apps/search/opensearch-admin >/dev/null 2>&1; then \
     vault kv patch kv/apps/search/opensearch-admin username=admin password='$OPENSEARCH_ADMIN_PASSWORD' passwordHash='$OPENSEARCH_ADMIN_PASSWORD_HASH'; \
   else \
     vault kv put kv/apps/search/opensearch-admin username=admin password='$OPENSEARCH_ADMIN_PASSWORD' passwordHash='$OPENSEARCH_ADMIN_PASSWORD_HASH'; \
   fi"

echo "Logging into Harbor OCI and image registries at ${HARBOR_HOST}"
helm registry login "$HARBOR_HOST" --username admin --password "$HARBOR_ADMIN_PASSWORD"

if command -v docker >/dev/null 2>&1; then
  docker login "$HARBOR_HOST" --username admin --password "$HARBOR_ADMIN_PASSWORD"
elif command -v podman >/dev/null 2>&1; then
  podman login "$HARBOR_HOST" --username admin --password "$HARBOR_ADMIN_PASSWORD"
elif command -v crane >/dev/null 2>&1; then
  crane auth login "$HARBOR_HOST" -u admin -p "$HARBOR_ADMIN_PASSWORD"
elif command -v skopeo >/dev/null 2>&1; then
  skopeo login --username admin --password "$HARBOR_ADMIN_PASSWORD" "$HARBOR_HOST"
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"; unset ROOT_TOKEN HARBOR_ADMIN_PASSWORD OPENSEARCH_ADMIN_PASSWORD OPENSEARCH_ADMIN_PASSWORD_HASH' EXIT

echo "Pulling upstream charts"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add opensearch https://opensearch-project.github.io/opensearch-k8s-operator >/dev/null
helm repo update >/dev/null

helm pull prometheus-community/kube-prometheus-stack \
  --version "$KPS_CHART_VERSION" \
  --destination "$WORKDIR"

helm pull opensearch/opensearch-operator \
  --version "$OPENSEARCH_OPERATOR_CHART_VERSION" \
  --destination "$WORKDIR"

echo "Pushing charts to ${HARBOR_CHARTS_REPO}"
helm push "${WORKDIR}/kube-prometheus-stack-${KPS_CHART_VERSION}.tgz" "$HARBOR_CHARTS_REPO"
helm push "${WORKDIR}/opensearch-operator-${OPENSEARCH_OPERATOR_CHART_VERSION}.tgz" "$HARBOR_CHARTS_REPO"

echo "Collecting kube-prometheus-stack image list"
KPS_TEMPLATE_ARGS=(
  kube-prometheus-stack
  prometheus-community/kube-prometheus-stack
  --version "$KPS_CHART_VERSION"
  --set global.imageRegistry=
)

if [[ -f "$KPS_VALUES_FILE" ]]; then
  KPS_TEMPLATE_ARGS+=(-f "$KPS_VALUES_FILE")
else
  echo "warning: ${KPS_VALUES_FILE} not found; templating kube-prometheus-stack with chart defaults for image discovery" >&2
fi

helm template "${KPS_TEMPLATE_ARGS[@]}" > "${WORKDIR}/kube-prometheus-stack.yaml"

mapfile -t KPS_IMAGES < <(
  sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "${WORKDIR}/kube-prometheus-stack.yaml" \
    | tr -d '"' \
    | tr -d "'" \
    | sort -u
)

EXTRA_IMAGES=(
  "docker.io/opensearchproject/opensearch-operator:2.8.0"
  "quay.io/brancz/kube-rbac-proxy:v0.15.0"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.87.1"
  "docker.io/library/busybox:1.31.1"
  "docker.io/opensearchproject/opensearch:3.4.0"
  "docker.io/library/busybox:1.36"
  "docker.io/opensearchproject/data-prepper:2.13.0"
  "cr.fluentbit.io/fluent/fluent-bit:4.2.2"
)

printf '%s\n' "${KPS_IMAGES[@]}" "${EXTRA_IMAGES[@]}" \
  | sort -u \
  > "${WORKDIR}/images.txt"

echo "Mirroring images to ${HARBOR_MIRROR_PREFIX}"
while IFS= read -r src; do
  [[ -n "$src" ]] || continue
  dst="${HARBOR_MIRROR_PREFIX}/$(strip_registry "$src")"
  echo "  ${src} -> ${dst}"
  mirror_image "$src" "$dst"
done < "${WORKDIR}/images.txt"

echo
echo "Vault path seeded:"
echo "  kv/apps/search/opensearch-admin"
echo
echo "Mirrored charts:"
echo "  ${HARBOR_CHARTS_REPO}/kube-prometheus-stack:${KPS_CHART_VERSION}"
echo "  ${HARBOR_CHARTS_REPO}/opensearch-operator:${OPENSEARCH_OPERATOR_CHART_VERSION}"
echo
echo "Mirrored images list:"
cat "${WORKDIR}/images.txt"
