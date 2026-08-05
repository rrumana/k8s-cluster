# Uptime Kuma access

`uptime.rcrumana.xyz` is published through the direct HAProxy edge and guarded
by the Authentik embedded outpost. Only members of `app-uptime-kuma` are
authorized. A Cilium ingress policy prevents other cluster workloads from
bypassing that edge and reaching the administrative Socket.IO API directly.

Uptime Kuma 2.4.0 does not provide a supported environment variable for
disabling its native login. After forward auth, Socket.IO, and rollback access
have been verified, disable it in **Settings > Security > Advanced**. All
authorized Authentik users will then share Kuma's first local administrator;
Kuma does not consume the Authentik identity headers or provide per-user RBAC.

Forward auth covers the entire host. Public status pages, push-monitor URLs,
API keys, and other browserless integrations therefore also require an
interactive Authentik session and should not be placed on this hostname.

To roll back after native login is disabled, first restore the private ingress
through GitOps. From LAN or Headscale, re-enable native authentication in Kuma,
verify its local login, and only then remove the Authentik provider.
