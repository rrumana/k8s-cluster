# Homepage

Runtime widget credentials are sourced from Vault through External Secrets.

## Vault Paths

Most Homepage-only values should live at:

```bash
kv/apps/productivity/homepage-env
```

The qBittorrent widgets reuse the existing media secrets:

- `kv/apps/media/qb-webui-creds`
- `kv/apps/media/qb-lts-webui-creds`
- `kv/apps/media/qb-lts2-webui-creds`

## Homepage Values

Set these properties on `kv/apps/productivity/homepage-env` as needed:

```text
HOMEPAGE_VAR_ARGOCD_TOKEN
HOMEPAGE_VAR_GRAFANA_USERNAME
HOMEPAGE_VAR_GRAFANA_PASSWORD
HOMEPAGE_VAR_UPTIME_KUMA_SLUG
HOMEPAGE_VAR_OPNSENSE_KEY
HOMEPAGE_VAR_OPNSENSE_SECRET
HOMEPAGE_VAR_OPNSENSE_WAN
HOMEPAGE_VAR_UNIFI_SITE
HOMEPAGE_VAR_UNIFI_USERNAME
HOMEPAGE_VAR_UNIFI_PASSWORD
HOMEPAGE_VAR_HEADSCALE_NODE_ID
HOMEPAGE_VAR_HEADSCALE_TOKEN
HOMEPAGE_VAR_TRUENAS_MEDIA_API_KEY
HOMEPAGE_VAR_TRUENAS_BACKUPS_API_KEY
HOMEPAGE_VAR_NEXTCLOUD_TOKEN
HOMEPAGE_VAR_ICAL_URL
HOMEPAGE_VAR_PLEX_TOKEN
HOMEPAGE_VAR_JELLYFIN_API_KEY
HOMEPAGE_VAR_IMMICH_API_KEY
HOMEPAGE_VAR_JELLYSEERR_API_KEY
HOMEPAGE_VAR_SONARR_API_KEY
HOMEPAGE_VAR_RADARR_API_KEY
HOMEPAGE_VAR_LIDARR_API_KEY
HOMEPAGE_VAR_PROWLARR_API_KEY
```

Example write:

```bash
ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && \
  vault kv patch kv/apps/productivity/homepage-env HOMEPAGE_VAR_PLEX_TOKEN='replace-me'"
unset ROOT_TOKEN
```

The `homepage-env` Kubernetes Secret is consumed with optional `envFrom`, so the
deployment can start before this Vault path exists. Environment-backed Homepage
config values are read at process start, so roll the pods after adding or
changing Vault values.
