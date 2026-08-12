#!/usr/bin/env bash
set -euo pipefail

HARBOR_HOST=${HARBOR_HOST:-harbor.rcrumana.xyz}
HARBOR_USERNAME=${HARBOR_USERNAME:-admin}
: "${HARBOR_PASSWORD:?Set HARBOR_PASSWORD to a Harbor account allowed to push thirdparty-charts and mirror}"

HARBOR_CHARTS_REPO="oci://${HARBOR_HOST}/thirdparty-charts"

# renovate: datasource=helm depName=gitea versioning=helm registryUrl=https://dl.gitea.com/charts/
GITEA_CHART_VERSION="12.7.0"
# renovate: datasource=helm depName=actions versioning=helm registryUrl=https://dl.gitea.com/charts/
ACTIONS_CHART_VERSION="0.1.2"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

mirror_image() {
  local source_image="$1"
  local destination_image="$2"
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

registry_login() {
  helm registry login "$HARBOR_HOST" \
    --username "$HARBOR_USERNAME" \
    --password-stdin <<<"$HARBOR_PASSWORD"

  crane auth login "$HARBOR_HOST" \
    --username "$HARBOR_USERNAME" \
    --password-stdin <<<"$HARBOR_PASSWORD"
}

need_cmd helm
need_cmd crane
need_cmd mktemp

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"; unset HARBOR_PASSWORD' EXIT

registry_login

helm repo add gitea https://dl.gitea.com/charts/ --force-update >/dev/null
helm repo update gitea >/dev/null
helm pull gitea/gitea --version "$GITEA_CHART_VERSION" --destination "$work_dir"
helm pull gitea/actions --version "$ACTIONS_CHART_VERSION" --destination "$work_dir"

helm push "${work_dir}/gitea-${GITEA_CHART_VERSION}.tgz" "$HARBOR_CHARTS_REPO"
helm push "${work_dir}/actions-${ACTIONS_CHART_VERSION}.tgz" "$HARBOR_CHARTS_REPO"

source_images=(
  "docker.gitea.com/gitea:1.27.0-rootless@sha256:caa57d932c7b78eb19b638dc38fd7c2f5512d4f90d8369c680a73bebf1b1de28"
  "docker.gitea.com/runner:2.0.1@sha256:3acd61cdcfe5dc05dda0a66029af457ac2ff803b8ae95ab13701f22b1136903e"
  "docker.gitea.com/runner-images:ubuntu-latest@sha256:cd31050dc1563b8aef5ea7b8d6704301ef92d908faed98c97ec0f2d82f559041"
  "docker.io/library/docker:29.5.2-dind-rootless@sha256:dc9035ef22486e1acddcc01602d5b6302dfd73b1c353df7f724bd0537ad0df63"
  "docker.io/library/busybox:1.38.0@sha256:1cfa4e2b09e127b9c4ed43578d3f3c18e7d44ea47b9ea98475c0cbe9086525f8"
  "docker.io/bitnami/valkey:latest@sha256:8ec3a39c0d650d76164688d6b0463e1760d4c0a7f09473587828c49b928a06a6"
  "docker.io/bitnami/valkey-sentinel:latest@sha256:e28132b5d4e6507c40afe6b0b6ec43bdf64870e0bb51a5ab938ef3757518c4cf"
  "docker.io/bitnami/redis-exporter:latest@sha256:5b10891636c5c53f475e8989130e5128a9d46aebf528bdea6e43b9409d538041"
)

destination_images=(
  "${HARBOR_HOST}/mirror/gitea/gitea:1.27.0-rootless"
  "${HARBOR_HOST}/mirror/gitea/runner:2.0.1"
  "${HARBOR_HOST}/mirror/gitea/runner-images:ubuntu-latest"
  "${HARBOR_HOST}/mirror/library/docker:29.5.2-dind-rootless"
  "${HARBOR_HOST}/mirror/library/busybox:1.38.0"
  "${HARBOR_HOST}/mirror/bitnami/valkey:latest"
  "${HARBOR_HOST}/mirror/bitnami/valkey-sentinel:latest"
  "${HARBOR_HOST}/mirror/bitnami/redis-exporter:latest"
)

echo "Mirroring pinned Gitea prerequisites"
for image_index in "${!source_images[@]}"; do
  mirror_image "${source_images[$image_index]}" "${destination_images[$image_index]}"
done

echo
echo "Seeded charts:"
echo "  ${HARBOR_CHARTS_REPO}/gitea:${GITEA_CHART_VERSION}"
echo "  ${HARBOR_CHARTS_REPO}/actions:${ACTIONS_CHART_VERSION}"
echo "Seeded ${#source_images[@]} pinned linux/amd64 image manifests."
