# Homepage

Runtime widget credentials are sourced from Vault through External Secrets.

## Vault Paths

Most Homepage-only values should live at:

```bash
kv/apps/productivity/homepage-env
```

The qBittorrent widgets reuse the existing media secrets:

- `kv/apps/media/qb-webui-creds`

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
HOMEPAGE_VAR_UNIFI_API_KEY
HOMEPAGE_VAR_TRUENAS_BACKUPS_API_KEY
HOMEPAGE_VAR_NEXTCLOUD_USERNAME
HOMEPAGE_VAR_NEXTCLOUD_PASSWORD
HOMEPAGE_VAR_JELLYFIN_API_KEY
HOMEPAGE_VAR_IMMICH_API_KEY
HOMEPAGE_VAR_JELLYSEERR_API_KEY
HOMEPAGE_VAR_SONARR_API_KEY
HOMEPAGE_VAR_RADARR_API_KEY
HOMEPAGE_VAR_LIDARR_API_KEY
HOMEPAGE_VAR_PROWLARR_API_KEY
```

The `homepage-env` Kubernetes Secret is consumed with optional `envFrom`, so the
deployment can start before this Vault path exists. Environment-backed Homepage
config values are read at process start, so roll the pods after adding or
changing Vault values.

## Node Cards

The six node cards use Homepage's `prometheusmetric` widget. Ready state comes
from kube-state-metrics, temperatures come from node-exporter, and CPU and RAM
come from kubelet's `/metrics/resource` endpoint. In particular, RAM uses
`node_memory_working_set_bytes`, which is the same source used by `kubectl top`,
rather than node-exporter's `MemTotal - MemAvailable` calculation.

Each card links to the chart-provided Node Exporter USE Method dashboard in
Grafana with the matching node-exporter instance selected.
