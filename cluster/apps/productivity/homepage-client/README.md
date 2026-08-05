# Homepage Client

Client-facing Homepage instance for `dashboard.rcrumana.xyz`.

The workload is intentionally separate from the administrator Homepage at
`dash.rcrumana.xyz`. Its configuration includes only client services, hosted
websites, the release calendar, and inert node metric cards. It has no links to
infrastructure administration surfaces.

## Access posture

The initial Ingress remains on `haproxy-restricted` and is limited to LAN and
Headscale source ranges. Keep that restriction until an Authentik forward-auth
provider, application, outpost, and HAProxy integration have been validated.
Only then should the Ingress be changed to the public direct-access posture.

## Runtime credentials

`homepage-client-env` projects only these existing properties from
`kv/apps/productivity/homepage-env`:

- `HOMEPAGE_VAR_JELLYFIN_API_KEY`
- `HOMEPAGE_VAR_JELLYSEERR_API_KEY`
- `HOMEPAGE_VAR_IMMICH_API_KEY`
- `HOMEPAGE_VAR_SONARR_API_KEY`
- `HOMEPAGE_VAR_RADARR_API_KEY`
- `HOMEPAGE_VAR_LIDARR_API_KEY`

The Nextcloud widget continues to read the existing `nextcloud-admin` Secret,
matching the administrator Homepage. No new Vault values are required.

The three ARR credentials exist only to retain the calendar integrations. Their
source service cards do not contain links and are hidden from the rendered
dashboard.
