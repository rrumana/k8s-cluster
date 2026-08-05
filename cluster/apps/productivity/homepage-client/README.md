# Homepage Client

Client-facing Homepage instance for `dashboard.rcrumana.xyz`.

The workload is intentionally separate from the administrator Homepage at
`dash.rcrumana.xyz`. Its configuration includes only client services, hosted
websites, the release calendar, and inert node metric cards. It has no links to
infrastructure administration surfaces.

## Access posture

The application Ingress remains on `haproxy-restricted` and is limited to LAN
and Headscale source ranges while the Authentik forward-auth integration is
validated. A separate public direct-edge Ingress routes only
`/outpost.goauthentik.io` to Authentik's embedded outpost because login,
callback, and logout endpoints must remain reachable throughout the flow.

Access requires membership in the GitOps-managed `app-homepage-client` group.
After unauthenticated redirects and an authorized login have been validated,
change the application Ingress to the public direct-access posture. Do not add
the authentication annotations to the outpost-path Ingress or it will create an
authentication loop.

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
