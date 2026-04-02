#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo scripts/emergency-cluster-dump.sh [--config /path/to/config] [--keep-staging]

Writes a single human-readable emergency dump to /NAS/dump.

Config is loaded from /etc/emergency-cluster-dump.conf by default. See
scripts/emergency-cluster-dump.conf.example for the supported variables.
EOF
}

log() {
  printf '[emergency-dump] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

CONFIG_PATH="${EMERGENCY_DUMP_CONFIG:-/etc/emergency-cluster-dump.conf}"
KEEP_STAGING=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift
      ;;
    --keep-staging)
      KEEP_STAGING=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Scalar defaults that can be overridden by the sourced config.
KUBECTL_MODE="${KUBECTL_MODE:-local}"
KUBECTL_SSH_TARGET="${KUBECTL_SSH_TARGET:-}"
NAS_ROOT="${NAS_ROOT:-/NAS}"
BITWARDEN_SERVER_URL="${BITWARDEN_SERVER_URL:-https://vault.rcrumana.xyz}"
VAULTWARDEN_ACCOUNTS_FILE="${VAULTWARDEN_ACCOUNTS_FILE:-}"
SECRET_NAME_SKIP_REGEX="${SECRET_NAME_SKIP_REGEX:-^(default-token-.*|harbor-pull-creds|sh\\.helm\\.release\\.v1\\..*)$}"
SECRET_TYPE_SKIP_REGEX="${SECRET_TYPE_SKIP_REGEX:-^(kubernetes\\.io/service-account-token|kubernetes\\.io/dockerconfigjson)$}"

if [[ -f "$CONFIG_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_PATH"
fi

if ! declare -p KUBECTL_SSH_ARGS >/dev/null 2>&1; then
  KUBECTL_SSH_ARGS=()
fi
if ! declare -p SECRET_NAMESPACE_ALLOWLIST >/dev/null 2>&1; then
  SECRET_NAMESPACE_ALLOWLIST=(security productivity media other ai web databases)
fi
if ! declare -p KNOWN_CLIENT_DEVICES >/dev/null 2>&1; then
  KNOWN_CLIENT_DEVICES=()
fi

DUMP_DIR="${DUMP_DIR:-$NAS_ROOT/dump}"

[[ "$EUID" -eq 0 ]] || die "run this script as root, for example: sudo scripts/emergency-cluster-dump.sh"

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  INVOKER_USER="$SUDO_USER"
  INVOKER_HOME="$(getent passwd "$INVOKER_USER" | cut -d: -f6)"
else
  INVOKER_USER="$(id -un)"
  INVOKER_HOME="$HOME"
fi

run_as_invoker() {
  if [[ "$INVOKER_USER" == "$(id -un)" ]]; then
    "$@"
  else
    sudo -u "$INVOKER_USER" \
      HOME="$INVOKER_HOME" \
      XDG_CONFIG_HOME="$INVOKER_HOME/.config" \
      SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}" \
      PATH="$PATH" \
      "$@"
  fi
}

kube() {
  if [[ "$KUBECTL_MODE" == "ssh" ]]; then
    [[ -n "$KUBECTL_SSH_TARGET" ]] || die "KUBECTL_MODE=ssh requires KUBECTL_SSH_TARGET"
    run_as_invoker ssh "${KUBECTL_SSH_ARGS[@]}" "$KUBECTL_SSH_TARGET" kubectl "$@"
  else
    run_as_invoker kubectl "$@"
  fi
}

pod_sh() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local script="$4"
  kube -n "$namespace" exec "$pod" -c "$container" -- sh -lc "$script"
}

copy_pod_dir() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local src_dir="$4"
  local dest_dir="$5"

  mkdir -p "$dest_dir"
  if [[ "$KUBECTL_MODE" == "ssh" ]]; then
    run_as_invoker ssh "${KUBECTL_SSH_ARGS[@]}" "$KUBECTL_SSH_TARGET" \
      kubectl -n "$namespace" exec "$pod" -c "$container" -- tar -C "$src_dir" -cf - . \
      | tar -xf - --no-same-owner -C "$dest_dir"
  else
    run_as_invoker kubectl -n "$namespace" exec "$pod" -c "$container" -- tar -C "$src_dir" -cf - . \
      | tar -xf - --no-same-owner -C "$dest_dir"
  fi
}

pod_dir_exists() {
  local namespace="$1"
  local pod="$2"
  local container="$3"
  local path="$4"

  pod_sh "$namespace" "$pod" "$container" "test -d '$path'" >/dev/null 2>&1
}

pg_query() {
  local cluster="$1"
  local host="$2"
  local port="$3"
  local user="$4"
  local db="$5"
  local password="$6"
  local sql="$7"
  local pod

  pod="$(kube -n databases get pods -l "cnpg.io/cluster=${cluster}" -o jsonpath='{.items[0].metadata.name}')"
  if [[ -z "$pod" ]]; then
    log "unable to find postgres pod for cluster ${cluster}"
    return 1
  fi

  kube -n databases exec "$pod" -- sh -lc \
    "export PGPASSWORD='$password'; psql -A -F '|' -t -h '$host' -p '$port' -U '$user' -d '$db' -c \"$sql\""
}

write_readme() {
  local readme_path="$1"
  cat >"$readme_path" <<EOF
Emergency dump created on $(date -u +"%Y-%m-%dT%H:%M:%SZ").

This directory is a plain-language copy of the family-critical data that was
still accessible when the dump was generated. It is intentionally simpler than
the live Kubernetes cluster.

Directory guide:
- vault/: deduplicated plaintext cluster secrets that were available through Kubernetes.
- vaultwarden/: plaintext Bitwarden-compatible exports grouped by user.
- nextcloud/: each user's owned files copied from Nextcloud.
- immich/: original uploaded Immich assets grouped by user.
- cluster-config/: a live cluster snapshot for the apps covered by this dump.
- _infra/: repo snapshot and generated metadata.

Important limitations:
- Nextcloud shared files stay under the original owner's directory in this dump.
- Immich-derived files like thumbnails and encoded videos are intentionally excluded.
- If an app could not be exported, check last-success.json and the notes in _infra/.
EOF
}

write_connect_device() {
  local path="$1"
  cat >"$path" <<EOF
# Connect A Device To The NAS

This dump lives at \`$DUMP_DIR\` on the NAS.

If the device already has the NAS mounted, open the \`dump\` directory directly.
If not, use the NAS access method already documented for the household and browse
to the same path once the share is mounted.
EOF
}

write_nextcloud_notes() {
  local path="$1"
  cat >"$path" <<'EOF'
This export mirrors each user's owned files from Nextcloud.

Shared files are kept under the original owner's directory. That means a person
who only had access through a share will need to look in the owner's folder.
EOF
}

write_status_json() {
  local path="$1"
  local started="$2"
  local finished="$3"
  local repo_commit="$4"
  local cluster_mode="$5"
  local vaultwarden_count="$6"
  local nextcloud_count="$7"
  local immich_count="$8"
  local overall_status="$9"
  local failed_steps_csv="${10}"

  python3 - "$path" "$started" "$finished" "$repo_commit" "$cluster_mode" "$vaultwarden_count" "$nextcloud_count" "$immich_count" "$overall_status" "$failed_steps_csv" <<'PY'
import json
import sys

path, started, finished, repo_commit, cluster_mode, vw_count, nc_count, im_count, overall_status, failed_steps_csv = sys.argv[1:]
payload = {
    "started_at": started,
    "finished_at": finished,
    "repo_commit": repo_commit,
    "kubectl_mode": cluster_mode,
    "vaultwarden_exports": int(vw_count),
    "nextcloud_users_exported": int(nc_count),
    "immich_users_exported": int(im_count),
    "overall_status": overall_status,
    "failed_steps": [step for step in failed_steps_csv.split(",") if step],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

finalize_permissions() {
  local root="$1"
  find "$root" -type d -exec chmod 0555 {} +
  find "$root" -type f -exec chmod 0444 {} +
}

record_step_status() {
  local step="$1"
  local status="$2"
  local message="$3"
  printf '%s\t%s\t%s\n' "$step" "$status" "$message" >>"$APP_STATUS_FILE"
}

run_step() {
  local step="$1"
  local description="$2"
  shift 2

  log "$description"
  if "$@"; then
    record_step_status "$step" "ok" ""
    return 0
  fi

  local rc=$?
  OVERALL_STATUS="partial"
  FAILED_STEPS+=("$step")
  mkdir -p "$STAGE_DIR/_infra/failures"
  printf 'step=%s\nexit_code=%s\n' "$step" "$rc" >"$STAGE_DIR/_infra/failures/${step}.txt"
  record_step_status "$step" "failed" "see _infra/failures/${step}.txt"
  log "${step} failed; continuing with the remaining exports"
  return 0
}

export_secrets_step() {
  local secrets_json="$TMP_DIR/secrets.json"
  local secret_args=()
  local ns

  kube get secrets -A -o json >"$secrets_json" || return 1
  for ns in "${SECRET_NAMESPACE_ALLOWLIST[@]}"; do
    secret_args+=(--namespace "$ns")
  done

  python3 "$SCRIPT_DIR/export-emergency-secrets.py" \
    --input "$secrets_json" \
    --output-dir "$STAGE_DIR/vault/unique-secrets" \
    --consolidated-file "$STAGE_DIR/vault/all-keys-consolidated-and-deduplicated.txt" \
    --duplicates-file "$STAGE_DIR/vault/duplicates.tsv" \
    --summary-file "$STAGE_DIR/vault/summary.json" \
    --skip-name-regex "$SECRET_NAME_SKIP_REGEX" \
    --skip-type-regex "$SECRET_TYPE_SKIP_REGEX" \
    "${secret_args[@]}" || return 1
}

write_cluster_snapshot_step() {
  local cluster_config="$STAGE_DIR/cluster-config/config.yaml"

  {
    printf '# Emergency dump cluster snapshot generated on %s\n' "$STARTED_AT"
    printf -- '---\n'
    kube get nodes -o yaml
    printf -- '---\n'
    kube get clustersecretstore vault -o yaml
    printf -- '---\n'
    kube -n productivity get deployment vaultwarden -o yaml
    printf -- '---\n'
    kube -n productivity get service vaultwarden -o yaml
    printf -- '---\n'
    kube -n productivity get ingress vaultwarden -o yaml
    printf -- '---\n'
    kube -n productivity get deployment nextcloud -o yaml
    printf -- '---\n'
    kube -n productivity get service nextcloud -o yaml
    printf -- '---\n'
    kube -n productivity get ingress nextcloud -o yaml
    printf -- '---\n'
    kube -n productivity get pvc nextcloud-appdata -o yaml
    printf -- '---\n'
    kube -n media get deployment immich-server -o yaml
    printf -- '---\n'
    kube -n media get deployment immich-machine-learning -o yaml
    printf -- '---\n'
    kube -n media get service immich-server -o yaml
    printf -- '---\n'
    kube -n media get ingress immich -o yaml
    printf -- '---\n'
    kube -n media get pvc immich-photos -o yaml
  } >"$cluster_config" || return 1
}

export_nextcloud_step() {
  local nextcloud_pod
  local nextcloud_datadir
  local nextcloud_users_tsv
  local username
  local display_name
  local user_dir

  nextcloud_pod="$(kube -n productivity get pods -o name | awk -F/ '/^pod\/nextcloud-/{print $2; exit}')" || return 1
  [[ -n "$nextcloud_pod" ]] || return 1

  nextcloud_datadir="$(pod_sh productivity "$nextcloud_pod" nextcloud 'cd /var/www/html && php occ config:system:get datadirectory')" || return 1
  nextcloud_users_tsv="$TMP_DIR/nextcloud-users.tsv"

  pod_sh productivity "$nextcloud_pod" nextcloud \
    "cd /var/www/html && php occ user:list | awk -F: '/^  - / {sub(/^  - /,\"\",\$1); sub(/^ /,\"\",\$2); print \$1 \"\t\" \$2}'" \
    >"$nextcloud_users_tsv" || return 1

  cp "$nextcloud_users_tsv" "$STAGE_DIR/nextcloud/users.tsv" || return 1
  write_nextcloud_notes "$STAGE_DIR/nextcloud/README.txt"

  NEXTCLOUD_EXPORTED=0
  while IFS=$'\t' read -r username display_name; do
    [[ -n "${username:-}" ]] || continue
    user_dir="$STAGE_DIR/nextcloud/$username"
    mkdir -p "$user_dir"
    printf 'username=%s\ndisplay_name=%s\n' "$username" "$display_name" >"$user_dir/user-info.txt"
    if pod_dir_exists productivity "$nextcloud_pod" nextcloud "$nextcloud_datadir/$username/files"; then
      copy_pod_dir productivity "$nextcloud_pod" nextcloud "$nextcloud_datadir/$username/files" "$user_dir/files" || return 1
      NEXTCLOUD_EXPORTED=$((NEXTCLOUD_EXPORTED + 1))
    fi
  done <"$nextcloud_users_tsv"
}

try_immich_user_map() {
  local output_tsv="$1"
  local host="$2"
  local port="$3"
  local user="$4"
  local db="$5"
  local password="$6"
  local candidates
  local schema
  local table
  local columns
  local chosen_schema=""
  local chosen_table=""
  local chosen_columns=""
  local label_expr
  local name_expr
  local email_expr
  local quoted_schema
  local quoted_table

  candidates="$(pg_query pg-media "$host" "$port" "$user" "$db" "$password" \
    "SELECT table_schema, table_name, string_agg(column_name, ',' ORDER BY column_name) \
     FROM information_schema.columns \
     WHERE table_schema NOT IN ('pg_catalog', 'information_schema') \
       AND column_name IN ('id', 'email', 'name') \
     GROUP BY table_schema, table_name \
     ORDER BY CASE WHEN table_name IN ('users', 'user') THEN 0 ELSE 1 END, table_schema, table_name;")" || return 1

  while IFS='|' read -r schema table columns; do
    [[ -n "${schema:-}" && -n "${table:-}" && -n "${columns:-}" ]] || continue
    [[ ",${columns}," == *",id,"* ]] || continue
    [[ ",${columns}," == *",email,"* ]] || continue
    chosen_schema="$schema"
    chosen_table="$table"
    chosen_columns="$columns"
    break
  done <<<"$candidates"

  [[ -n "$chosen_table" ]] || return 1

  if [[ ",${chosen_columns}," == *",name,"* ]]; then
    label_expr="COALESCE(NULLIF(name, ''), NULLIF(email, ''), id::text)"
    name_expr="COALESCE(name, '')"
  else
    label_expr="COALESCE(NULLIF(email, ''), id::text)"
    name_expr="''"
  fi
  email_expr="COALESCE(email, '')"

  quoted_schema="${chosen_schema//\"/\"\"}"
  quoted_table="${chosen_table//\"/\"\"}"

  pg_query pg-media "$host" "$port" "$user" "$db" "$password" \
    "SELECT id::text, ${label_expr}, ${name_expr}, ${email_expr} FROM \"${quoted_schema}\".\"${quoted_table}\" ORDER BY id::text;" \
    >"$output_tsv" || return 1

  printf 'schema=%s\ntable=%s\ncolumns=%s\n' "$chosen_schema" "$chosen_table" "$chosen_columns" \
    >"$STAGE_DIR/immich/user-table-source.txt"
}

export_immich_step() {
  local immich_pod
  local immich_db_host
  local immich_db_port
  local immich_db_user
  local immich_db_name
  local immich_db_password
  local immich_fs_users
  local immich_library_users
  local immich_upload_users
  local immich_users_tsv
  local immich_readme
  local source_dir
  local user_id
  local label
  local name
  local email
  local base_label
  local user_dir
  declare -A immich_label_by_id=()
  declare -A immich_name_by_id=()
  declare -A immich_email_by_id=()
  declare -A immich_seen_labels=()

  immich_pod="$(kube -n media get pods -o name | awk -F/ '/^pod\/immich-server-/{print $2; exit}')" || return 1
  [[ -n "$immich_pod" ]] || return 1

  immich_readme="$STAGE_DIR/immich/README.txt"
  cat >"$immich_readme" <<'EOF'
This export contains the original uploaded assets from Immich.

Only the original uploads are copied. Derived data such as thumbnails, encoded
videos, model cache, and database internals are intentionally excluded.
EOF

  immich_library_users="$TMP_DIR/immich-library-users.txt"
  immich_upload_users="$TMP_DIR/immich-upload-users.txt"
  immich_fs_users="$TMP_DIR/immich-fs-users.txt"

  if pod_dir_exists media "$immich_pod" immich-server "/usr/src/app/upload/library"; then
    pod_sh media "$immich_pod" immich-server \
      "find /usr/src/app/upload/library -mindepth 1 -maxdepth 1 -type d | sed 's#.*/##' | sort" \
      >"$immich_library_users" || return 1
  else
    : >"$immich_library_users"
  fi

  if pod_dir_exists media "$immich_pod" immich-server "/usr/src/app/upload/upload"; then
    pod_sh media "$immich_pod" immich-server \
      "find /usr/src/app/upload/upload -mindepth 1 -maxdepth 1 -type d | sed 's#.*/##' | sort" \
      >"$immich_upload_users" || return 1
  else
    : >"$immich_upload_users"
  fi

  cat "$immich_library_users" "$immich_upload_users" | awk 'NF' | sort -u >"$immich_fs_users" || return 1
  cp "$immich_fs_users" "$STAGE_DIR/immich/user-ids.txt" || return 1

  immich_db_host="$(kube -n media get configmap immich-config -o jsonpath='{.data.DB_HOSTNAME}')" || return 1
  immich_db_port="$(kube -n media get configmap immich-config -o jsonpath='{.data.DB_PORT}')" || return 1
  immich_db_user="$(kube -n media get configmap immich-config -o jsonpath='{.data.DB_USERNAME}')" || return 1
  immich_db_name="$(kube -n media get configmap immich-config -o jsonpath='{.data.DB_DATABASE_NAME}')" || return 1
  immich_db_password="$(kube -n media get secret immich-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)" || return 1
  immich_users_tsv="$TMP_DIR/immich-users.tsv"

  if try_immich_user_map "$immich_users_tsv" "$immich_db_host" "$immich_db_port" "$immich_db_user" "$immich_db_name" "$immich_db_password"; then
    cp "$immich_users_tsv" "$STAGE_DIR/immich/users.tsv" || return 1
    printf '\nUser directories were labeled from the Immich database when possible.\n' >>"$immich_readme"
    while IFS='|' read -r user_id label name email; do
      [[ -n "${user_id:-}" ]] || continue
      immich_label_by_id["$user_id"]="$label"
      immich_name_by_id["$user_id"]="$name"
      immich_email_by_id["$user_id"]="$email"
    done <"$immich_users_tsv"
  else
    printf '\nThe dump could not map Immich user IDs back to account metadata, so raw user IDs are used as folder names.\n' >>"$immich_readme"
  fi

  IMMICH_EXPORTED=0
  while IFS= read -r user_id; do
    [[ -n "${user_id:-}" ]] || continue
    label="${immich_label_by_id[$user_id]:-$user_id}"
    name="${immich_name_by_id[$user_id]:-}"
    email="${immich_email_by_id[$user_id]:-}"
    base_label="$(sanitize_name "$label")"
    if [[ -n "${immich_seen_labels[$base_label]:-}" ]]; then
      base_label="${base_label}-$(printf '%s' "$user_id" | cut -c1-8)"
    fi
    immich_seen_labels["$base_label"]=1
    user_dir="$STAGE_DIR/immich/$base_label"
    mkdir -p "$user_dir"
    source_dir=""
    if pod_dir_exists media "$immich_pod" immich-server "/usr/src/app/upload/library/$user_id"; then
      source_dir="/usr/src/app/upload/library/$user_id"
    elif pod_dir_exists media "$immich_pod" immich-server "/usr/src/app/upload/upload/$user_id"; then
      source_dir="/usr/src/app/upload/upload/$user_id"
    else
      continue
    fi
    printf 'user_id=%s\nlabel=%s\nname=%s\nemail=%s\nsource_dir=%s\n' "$user_id" "$label" "$name" "$email" "$source_dir" >"$user_dir/user-info.txt"
    copy_pod_dir media "$immich_pod" immich-server "$source_dir" "$user_dir/originals" || return 1
    IMMICH_EXPORTED=$((IMMICH_EXPORTED + 1))
  done <"$immich_fs_users"
}

export_vaultwarden_step() {
  local vw_db_host
  local vw_db_port
  local vw_db_name
  local vw_db_user
  local vw_db_pass
  local vw_live_users
  local label
  local email
  local password_file
  local slug
  local user_dir
  local bw_state_dir
  local bw_json
  local bw_csv
  local login_session
  local unlock_session
  local configured_accounts
  local live_vw_count

  [[ -n "$VAULTWARDEN_ACCOUNTS_FILE" ]] || return 1
  [[ -f "$VAULTWARDEN_ACCOUNTS_FILE" ]] || return 1

  vw_db_host="$(kube -n productivity get secret vaultwarden-db-shared -o jsonpath='{.data.host}' | base64 -d)" || return 1
  vw_db_port="$(kube -n productivity get secret vaultwarden-db-shared -o jsonpath='{.data.port}' | base64 -d)" || return 1
  vw_db_name="$(kube -n productivity get secret vaultwarden-db-shared -o jsonpath='{.data.database}' | base64 -d)" || return 1
  vw_db_user="$(kube -n productivity get secret vaultwarden-db-shared -o jsonpath='{.data.username}' | base64 -d)" || return 1
  vw_db_pass="$(kube -n productivity get secret vaultwarden-db-shared -o jsonpath='{.data.password}' | base64 -d)" || return 1
  vw_live_users="$TMP_DIR/vaultwarden-live-users.txt"
  pg_query pg-productivity "$vw_db_host" "$vw_db_port" "$vw_db_user" "$vw_db_name" "$vw_db_pass" \
    "SELECT email FROM users ORDER BY email;" >"$vw_live_users" || return 1
  cp "$vw_live_users" "$STAGE_DIR/vaultwarden/live-users.txt" || return 1

  VAULTWARDEN_EXPORTED=0
  configured_accounts=0
  while IFS=$'\t' read -r label email password_file; do
    [[ -n "${label:-}" ]] || continue
    [[ "${label:0:1}" == "#" ]] && continue
    [[ -n "${email:-}" ]] || return 1
    [[ -f "$password_file" ]] || return 1
    configured_accounts=$((configured_accounts + 1))
    grep -Fxq "$email" "$vw_live_users" || return 1

    slug="$(sanitize_name "$label")"
    user_dir="$STAGE_DIR/vaultwarden/$slug"
    mkdir -p "$user_dir"
    printf 'label=%s\nemail=%s\n' "$label" "$email" >"$user_dir/user-info.txt"

    bw_state_dir="$(run_as_invoker mktemp -d "/tmp/emergency-cluster-dump-bw.${slug}.XXXXXX")" || return 1
    bw_json="${bw_state_dir}/passwords.json"
    bw_csv="${bw_state_dir}/passwords.csv"

    run_as_invoker env BITWARDENCLI_APPDATA_DIR="$bw_state_dir" bw config server "$BITWARDEN_SERVER_URL" >/dev/null || return 1
    login_session="$(run_as_invoker env BITWARDENCLI_APPDATA_DIR="$bw_state_dir" bw login --nointeraction --raw "$email" --passwordfile "$password_file")" || return 1
    unlock_session="$(run_as_invoker env BITWARDENCLI_APPDATA_DIR="$bw_state_dir" bw unlock --nointeraction --raw --passwordfile "$password_file" --session "$login_session")" || return 1
    run_as_invoker env BITWARDENCLI_APPDATA_DIR="$bw_state_dir" bw sync --nointeraction --session "$unlock_session" >/dev/null || return 1
    run_as_invoker env BITWARDENCLI_APPDATA_DIR="$bw_state_dir" bw export --nointeraction --format json --output "$bw_json" --session "$unlock_session" >/dev/null || return 1
    run_as_invoker env BITWARDENCLI_APPDATA_DIR="$bw_state_dir" bw export --nointeraction --format csv --output "$bw_csv" --session "$unlock_session" >/dev/null || return 1
    run_as_invoker env BITWARDENCLI_APPDATA_DIR="$bw_state_dir" bw logout --nointeraction >/dev/null || true

    install -m 0644 "$bw_json" "$user_dir/passwords.json" || return 1
    install -m 0644 "$bw_csv" "$user_dir/passwords.csv" || return 1
    rm -rf "$bw_state_dir"
    VAULTWARDEN_EXPORTED=$((VAULTWARDEN_EXPORTED + 1))
  done <"$VAULTWARDEN_ACCOUNTS_FILE"

  live_vw_count="$(grep -cve '^[[:space:]]*$' "$vw_live_users")"
  [[ "$configured_accounts" -eq "$live_vw_count" ]] || return 1
}

STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
STAGE_DIR="${NAS_ROOT}/.dump-staging-${RUN_ID}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/emergency-cluster-dump.XXXXXX")"

cleanup() {
  local status=$?
  if [[ $status -ne 0 ]]; then
    log "dump failed; staging preserved at $STAGE_DIR"
  elif [[ "$KEEP_STAGING" -eq 0 && -d "$STAGE_DIR" ]]; then
    :
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_cmd kubectl
require_cmd python3
require_cmd tar
require_cmd base64
require_cmd git
require_cmd sudo
require_cmd bw
if [[ "$KUBECTL_MODE" == "ssh" ]]; then
  require_cmd ssh
fi

[[ -d "$NAS_ROOT" ]] || die "NAS root not found: $NAS_ROOT"
touch "${NAS_ROOT}/.emergency-dump-write-test"
rm -f "${NAS_ROOT}/.emergency-dump-write-test"

log "checking cluster access"
kube get nodes >/dev/null

log "checking Vault readiness"
vault_status="$(kube -n security exec vault-0 -- vault status)"
grep -q 'Sealed[[:space:]]*false' <<<"$vault_status" || die "Vault is sealed; unseal Vault before running the dump"
kube get clustersecretstore vault -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q '^True$' \
  || die "ClusterSecretStore/vault is not Ready"

cat <<'EOF'
This dump may take a while.
The script will print a completion message when it is done.
Take a walk or talk to someone you love while it runs.
EOF

mkdir -p "$STAGE_DIR"
mkdir -p "$STAGE_DIR/vault" "$STAGE_DIR/vaultwarden" "$STAGE_DIR/nextcloud" "$STAGE_DIR/immich" \
  "$STAGE_DIR/cluster-config" "$STAGE_DIR/_infra"

write_readme "$STAGE_DIR/README-FIRST.txt"
write_connect_device "$STAGE_DIR/connect-device.md"
APP_STATUS_FILE="$STAGE_DIR/_infra/app-status.tsv"
mkdir -p "$STAGE_DIR/_infra/failures"
printf 'step\tstatus\tnote\n' >"$APP_STATUS_FILE"
OVERALL_STATUS="success"
FAILED_STEPS=()
NEXTCLOUD_EXPORTED=0
IMMICH_EXPORTED=0
VAULTWARDEN_EXPORTED=0

REPO_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"
git -C "$REPO_ROOT" status --short >"$STAGE_DIR/_infra/repo-status.txt" || true
printf '%s\n' "$REPO_COMMIT" >"$STAGE_DIR/_infra/repo-commit.txt"

run_step secrets "exporting deduplicated cluster secrets" export_secrets_step
run_step cluster-config "writing cluster snapshot" write_cluster_snapshot_step
run_step nextcloud "exporting Nextcloud files" export_nextcloud_step
run_step immich "exporting Immich originals" export_immich_step
run_step vaultwarden "exporting Vaultwarden accounts" export_vaultwarden_step

mkdir -p "$STAGE_DIR/_infra/repo-snapshot"
cp -a "$REPO_ROOT/cluster/apps/productivity/vaultwarden" "$STAGE_DIR/_infra/repo-snapshot/"
cp -a "$REPO_ROOT/cluster/apps/productivity/nextcloud" "$STAGE_DIR/_infra/repo-snapshot/"
cp -a "$REPO_ROOT/cluster/apps/media/immich" "$STAGE_DIR/_infra/repo-snapshot/"
cp -a "$REPO_ROOT/cluster/apps/shared/ingress/vaultwarden.yaml" "$STAGE_DIR/_infra/repo-snapshot/"
cp -a "$REPO_ROOT/cluster/apps/shared/ingress/nextcloud.yaml" "$STAGE_DIR/_infra/repo-snapshot/"
cp -a "$REPO_ROOT/cluster/apps/shared/ingress/immich.yaml" "$STAGE_DIR/_infra/repo-snapshot/"
cp -a "$REPO_ROOT/docs/vault-operations.md" "$STAGE_DIR/_infra/repo-snapshot/"

FINISHED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
write_status_json "$STAGE_DIR/last-success.json" "$STARTED_AT" "$FINISHED_AT" "$REPO_COMMIT" \
  "$KUBECTL_MODE" "$VAULTWARDEN_EXPORTED" "$NEXTCLOUD_EXPORTED" "$IMMICH_EXPORTED" "$OVERALL_STATUS" "$(IFS=,; printf '%s' "${FAILED_STEPS[*]:-}")"

(cd "$STAGE_DIR" && find . | sort) >"$STAGE_DIR/_infra/manifest.txt"

BACKUP_DIR=""
if [[ -e "$DUMP_DIR" ]]; then
  BACKUP_DIR="${NAS_ROOT}/.dump-backup-${RUN_ID}"
  mv "$DUMP_DIR" "$BACKUP_DIR"
fi
mv "$STAGE_DIR" "$DUMP_DIR"
finalize_permissions "$DUMP_DIR"
if [[ -n "$BACKUP_DIR" ]]; then
  rm -rf "$BACKUP_DIR"
fi

if [[ "$OVERALL_STATUS" == "partial" ]]; then
  log "dump completed with warnings"
else
  log "dump completed"
fi
printf 'Files located at %s\n' "$DUMP_DIR"
if [[ "${#KNOWN_CLIENT_DEVICES[@]}" -gt 0 ]]; then
  printf 'Accessible on the following client devices:\n'
  for device in "${KNOWN_CLIENT_DEVICES[@]}"; do
    printf '  - %s\n' "$device"
  done
fi
if [[ "$OVERALL_STATUS" == "partial" ]]; then
  printf 'Some exports failed. See %s and %s\n' "$DUMP_DIR/last-success.json" "$DUMP_DIR/_infra/app-status.tsv"
fi
printf 'Instructions for connecting new devices are in %s\n' "$DUMP_DIR/connect-device.md"
