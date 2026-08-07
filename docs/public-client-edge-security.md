# Public client edge security

Client services use direct DNS-only HTTPS through the HAProxy ingress address.
Cloudflare is not in the authenticated request path.

## Identity rate limit

HAProxy tracks requests by source address over ten seconds and returns `429`
after more than twenty requests to one of these public identity entry points:

- Authentik authentication, recovery, and client-enrollment flow pages
- The corresponding Authentik flow-executor API paths
- Forward-auth initiation for Dashboard, HyperMind, and Uptime Kuma

LAN, cluster, and Headscale source ranges are exempt. The rule intentionally
does not match OIDC callbacks, ordinary application requests, Jellyfin media,
Nextcloud synchronization, or Immich uploads. The table is local to each of the
three HAProxy replicas; it is a protective throttle, not an accounting quota.

## Workload ingress isolation

NetworkPolicies restrict the HTTP listeners for Authentik, Dashboard,
LibreChat, Immich, Nextcloud, Vaultwarden, Jellyfin, and the shared ARR/Seerr
pod to HAProxy. Explicit exceptions retain:

- Homepage and client-dashboard widget calls
- Linkerd and Prometheus administration/metrics traffic
- The narrowly selected Jellyfin identity-bootstrap Job on Jellyfin's HTTP port
- Jellyfin's existing direct LAN/Headscale LoadBalancer and discovery access
- Every private web listener in the shared Gluetun/Servarr/Seerr pod

The policies are ingress-only and do not alter application egress. This is
especially important for Seerr: it remains beside Radarr and Sonarr and keeps
its existing loopback and Gluetun behavior.

HyperMind remains the deliberate exception. Its upstream Hyperswarm/DHT design
uses `hostNetwork`, and Cilium host-firewall enforcement is not enabled on this
cluster. The public HTTP path is still guarded by Authentik at HAProxy, while
direct TCP/3000 access is limited by the absence of a WAN port forward and the
trusted LAN boundary. Do not describe a pod NetworkPolicy as protecting it.

## Public cutover prerequisites

Before external testing, create DNS-only CNAMEs for these names pointing to
`direct.rcrumana.xyz`:

- `jellyfin.rcrumana.xyz`
- `jellyseerr.rcrumana.xyz`
- `vault.rcrumana.xyz`

The public Ingresses terminate TLS at HAProxy. Vaultwarden `/admin` retains a
separate HAProxy ACL and must return `403` outside LAN and Headscale even though
the client and API paths are public.

## External verification

From a cellular or otherwise external connection, verify:

1. Jellyfin browser SSO succeeds and native/TV Quick Connect remains usable.
2. Seerr Quick Connect creates or associates the expected Jellyfin user and a
   request reaches the existing Radarr or Sonarr integration.
3. Vaultwarden web, browser-extension, desktop, Android, and iOS clients can
   log in and synchronize against `https://vault.rcrumana.xyz`.
4. `https://vault.rcrumana.xyz/admin` returns `403`.
5. Registration without an administrator-issued Vaultwarden invitation fails.
6. Repeated identity-flow requests receive `429`, while normal application
   traffic remains unaffected.
