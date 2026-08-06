# Identity and direct-access rollout

This runbook turns on the GitOps resources for self-hosted identity without
publishing Immich or Nextcloud before their OIDC clients are ready. The cluster
is live: execute one phase at a time and finish its verification before moving
on.

## Exposure model

| Host | Public edge | Intended access |
|---|---|---|
| `auth.rcrumana.xyz` | DNS-only/direct | Invited users |
| `immich.rcrumana.xyz` | DNS-only/direct after OIDC cutover | `app-immich` |
| `nextcloud.rcrumana.xyz` | DNS-only/direct after OIDC cutover | `app-nextcloud` |
| `collabora.rcrumana.xyz` | DNS-only/direct | Nextcloud-issued WOPI sessions |
| `whiteboard.rcrumana.xyz` | DNS-only/direct | Nextcloud-issued JWT sessions |
| `headscale.rcrumana.xyz` | DNS-only/direct | Infrastructure users |
| `harbor.rcrumana.xyz` | No public record | LAN and Headscale |
| `rcrumana.xyz`, `staging.rcrumana.xyz` | Cloudflare proxy | Public visitors |

`haproxy` is the public class. `haproxy-restricted` is the private class. A
public Ingress must additionally state whether its edge is `direct` or
`cloudflare`. Cloudflare-edge Ingresses accept origin traffic only from
Cloudflare and private/Headscale networks.

## Phase 0: containment and credential rotation

1. Reconcile the Harbor values change before any identity work.
2. Delete the public Cloudflare DNS record for `harbor.rcrumana.xyz`.
3. Keep the Unbound host override pointing Harbor to `192.168.1.230`.
4. Rotate the Mailgun SMTP credential that was reused by an operational
   account. Rotate every other account that shared the old value and invalidate
   it.
5. Create separate Mailgun SMTP users for Authentik, Immich, Nextcloud, and
   Vaultwarden.
   Standardize the From addresses as:
   - `auth@mail.rcrumana.xyz`
   - `immich@mail.rcrumana.xyz`
   - `nextcloud@mail.rcrumana.xyz`
   - `vaultwarden@mail.rcrumana.xyz`
6. Send test messages from the existing Immich and Nextcloud installations.
   Verify Mailgun acceptance plus SPF and DKIM before enabling invitation mail.

Never place an SMTP password, OIDC client secret, invitation token, passkey
material, or recovery code in Git.

## Vault prerequisites

Create these KV v2 entries before enabling the corresponding Argo CD
application or overlay:

| Vault path | Required properties |
|---|---|
| `apps/identity/authentik` | `secret-key`, `postgresql-username`, `postgresql-password`, `smtp-username`, `smtp-password`, `oidc-immich-client-secret`, `oidc-nextcloud-client-secret`, `oidc-headscale-client-secret`, `oidc-jellyfin-client-secret` |
| `apps/media/immich-identity` | `config.json` |
| `apps/media/jellyfin-identity` | `client-secret` |
| `apps/productivity/nextcloud-identity` | `client-id`, `client-secret`, `whiteboard-jwt-secret` |
| `apps/productivity/nextcloud-mail` | `host`, `username`, `password` |
| `apps/productivity/vaultwarden-access` | `admin-token`, `smtp-username`, `smtp-password` |
| `apps/other/headscale-identity` | `client-id`, `client-secret` |

The script generates independent Authentik, PostgreSQL, and OIDC values. SMTP
usernames and passwords come from the dedicated credentials created in
Mailgun. The Authentik and application copy of each OIDC client secret must
match.

Copy `scripts/seed-identity-prereqs.sh` and a complete current Immich
configuration export to the Balthasar directory containing `vault-init.json`.
Run the script from that directory; it is self-contained and does not require a
repository checkout. It prompts for the Mailgun credentials, generates the
internal values, merges the Immich identity configuration, and creates these
paths without exposing secret values in shell history. Authentik uses the
existing shared pull credential at
`apps/productivity/harbor-pull-creds`; the script does not create or rotate a
Harbor account.

The Immich `config.json` value must be a complete export of the current Immich
system configuration, not merely the example committed beside the overlay.
Merge the OIDC and new SMTP values into that export. Keep password login enabled
during the pilot. The example exists to document the required identity fields
and must not be used verbatim.

For Vaultwarden, copy `scripts/seed-vaultwarden-access.sh` to the Balthasar
directory containing `vault-init.json` and run it from that directory. It
prompts for the dedicated Mailgun credential and an administrator password,
stores only an Argon2id hash of the administrator password, and creates
`apps/productivity/vaultwarden-access` without printing secret material. It
refuses to overwrite an existing path so a rerun cannot silently rotate access.

Vaultwarden intentionally uses native invitation, master-password, and MFA
authentication rather than Authentik. Public registration remains disabled.
The `/admin` path is additionally restricted to LAN and Headscale sources even
after the main Vaultwarden Ingress is made public.

Use the Vaultwarden administrator page for user invitations and diagnostics.
Do not save application configuration through that page unless the same change
is first represented in GitOps: `/data/config.json` values override environment
variables and can otherwise make the live configuration diverge from this repo.

The Jellyfin pilot uses the same pattern. Copy
`scripts/seed-jellyfin-identity-secret.sh` beside `vault-init.json` on
Balthasar and run it there. The deployment reuses the existing Homepage
Jellyfin API key only for its declarative plugin and login-button bootstrap; it
does not create another Jellyfin service account.

Seerr remains on a stable upstream release rather than the experimental OIDC
preview. Stable `v3.4.1` supports Jellyfin Quick Connect, so users authenticate
to Jellyfin through Authentik and authorize the Seerr login code from their
Jellyfin session. Local Seerr sign-in is disabled; direct Jellyfin credentials
remain available as a compatibility fallback. This preserves Seerr's existing
Jellyfin user IDs and request attribution without maintaining a vulnerable
preview image or placing forward-auth in front of its API.

## OPNsense

Export the OPNsense configuration before making changes.

1. Define alias `K8S_INGRESS_VIP` as `192.168.1.230`.
2. The only public Kubernetes port forwards should be:
   - WAN TCP 443 to `K8S_INGRESS_VIP:443`
   - WAN TCP 80 to `K8S_INGRESS_VIP:80` for HTTPS redirects
3. Enable logging on those rules.
4. Confirm there are no WAN forwards to the Kubernetes API, nodes,
   `192.168.1.232-192.168.1.236`, Ceph/NFS, UniFi, or Harbor.
5. Prevent UPnP from creating rules into the node and MetalLB ranges.
6. Keep Unbound split-DNS overrides for cluster names pointed at
   `192.168.1.230`.
7. Disable NAT reflection for these names; split DNS provides internal routing.
8. Do not publish IPv6/AAAA records during this rollout.

The emergency containment action is disabling the two WAN rules. This must not
affect LAN or Headscale access.

## Cloudflare DNS

Create:

```text
direct.rcrumana.xyz  A      <WAN IPv4>             DNS only, TTL 300
auth.rcrumana.xyz    CNAME  direct.rcrumana.xyz    DNS only, TTL 300
immich.rcrumana.xyz  CNAME  direct.rcrumana.xyz    DNS only, TTL 300
nextcloud.rcrumana.xyz CNAME direct.rcrumana.xyz   DNS only, TTL 300
collabora.rcrumana.xyz CNAME direct.rcrumana.xyz  DNS only, TTL 300
whiteboard.rcrumana.xyz CNAME direct.rcrumana.xyz DNS only, TTL 300
headscale.rcrumana.xyz CNAME direct.rcrumana.xyz   DNS only, TTL 300
```

Keep the portfolio records proxied. Delete Harbor's public record. Once
external validation is complete, raise the direct-record TTL to 3600.

Cloudflare remains the DNS-01 provider for cert-manager. DNS-only application
records must never be changed to proxied as a routine configuration because
large uploads, native clients, and source-address policy depend on direct
connections.

For future DDNS, install OPNsense `os-ddclient`, issue a Cloudflare token with
DNS-edit access limited to this zone, and update only
`direct.rcrumana.xyz`. Expected retrofit time is one to three hours including a
forced update test and alerting.

## Authentik bootstrap and policy

1. Confirm the Authentik ExternalSecrets are Ready.
2. Manually sync the Authentik Argo CD application for the first deployment.
3. Connect through LAN or Headscale first and replace the bootstrap credential.
4. Store the break-glass administrator credential offline. Do not use it for
   routine administration.
5. Confirm the declarative groups exist:
   - `app-homepage-client`
   - `app-hypermind`
   - `app-immich`
   - `app-jellyfin`
   - `app-librechat`
   - `app-nextcloud`
   - `app-uptime-kuma`
   - `headscale-users`
   - `platform-admins`
6. Confirm public enrollment is disabled.
7. Send a client invitation to a test address using only the fixed `email`
   field. It must be single-use and expire in 72 hours. Application groups are
   assigned by policy; `app_groups` is intentionally rejected.
8. Complete email verification, password setup, passkey registration, TOTP
   authenticator registration, and recovery-code generation.
9. Verify passkey-first login and password plus TOTP, email OTP, and recovery
   code fallbacks. Authentik may prefer the last successfully used fallback on
   a later password login, so verify that the user can explicitly select every
   enrolled method.
10. Verify `/if/admin/` is unavailable from a public source but available
    through Headscale.

Use `docs/client-identity-operations.md` for the complete operator checklist
and send `docs/client-onboarding.md` to invited clients.

Only after these checks should `auth.rcrumana.xyz` be published as DNS-only.

## Immich cutover

1. In Authentik, verify the `immich` provider has only these redirects:
   - `app.immich:///oauth-callback`
   - `https://immich.rcrumana.xyz/auth/login`
   - `https://immich.rcrumana.xyz/user-settings`
2. Configure the back-channel logout URI as
   `https://immich.rcrumana.xyz/api/oauth/backchannel-logout`.
3. Export the current Immich configuration from the administration page.
4. Merge the OIDC settings and dedicated SMTP credential into the export and
   write the complete JSON document to the Vault path above.
5. Change the Immich Argo CD source path from
   `cluster/apps/media/immich` to
   `cluster/apps/media/immich-identity`.
6. Sync and validate OIDC while the Ingress remains private.
7. Invite a test user into `app-immich`.
8. After web, iOS, Android, refresh, logout, upload, and mail tests pass, change
   the shared Immich Ingress to:
   - class `haproxy`
   - exposure `public`
   - public approval `"true"`
   - public edge `direct`
   - no private source allowlist

Rollback by restoring the base Argo path and private Ingress. The local Immich
administrator and password login remain available during the pilot.

## Nextcloud cutover

The pinned derived image from
`cluster/apps/productivity/nextcloud/image/Dockerfile` has been built and
published:

```text
harbor.rcrumana.xyz/apps-private/nextcloud:33.0.0-user_oidc-8.10.1
sha256:ff71a5b9d74d8d9db95e5679de069b7b0d7a46ab502789320c914648adab65f4
```

The build verifies the upstream `user_oidc` 8.10.1 archive against its committed
SHA-256 digest.

1. Populate `apps/productivity/nextcloud-identity` in Vault.
2. Add `identity-externalsecret.yaml` to the Nextcloud kustomization.
3. Add `$values/cluster/apps/productivity/nextcloud/values-identity.yaml` after
   the existing values file in the Nextcloud Argo CD application.
4. Sync while the Ingress remains private.
5. Verify the `user_oidc` app is enabled and the `authentik` provider exists.
6. Invite a new test user into `app-nextcloud`. Do not merge the existing local
   administrator into OIDC.
7. Test browser, desktop, mobile, WebDAV, app passwords, sharing, large uploads,
   logout, and SMTP.
8. Make the shared Nextcloud Ingress public using the same four direct-edge
   settings listed for Immich.

The before-starting hook is idempotent, reads the client secret from an
environment variable, maps the stable `sub` claim to the Nextcloud UID, and
rejects users outside `app-nextcloud`. Normal login redirects directly to
Authentik. The local administrator remains available for break-glass recovery
at `https://nextcloud.rcrumana.xyz/login?direct=1`; keep its password offline
and test this path after identity changes. HAProxy permits that direct-login
query only from RFC1918 LAN addresses and the Headscale `100.64.0.0/10` range;
public clients receive HTTP 403 before the request reaches Nextcloud.

The chart mounts a pod-local `emptyDir` at `/tmp/nextcloud-temp` in both the web
and cron containers. A least-capability init container recreates it as UID/GID
33 with mode `0700` before every pod start. The identity hook also declares the
public-share policy idempotently: link sharing, public uploads, resharing,
federation, custom tokens, and view-without-download are available, while link
passwords and expiry dates remain optional. User-enumeration controls are not
relaxed by this policy.

Collabora and the Whiteboard collaboration server are browser-facing parts of
Nextcloud integrations, not standalone login surfaces. Do not place Authentik
in front of either backend: Collabora validates Nextcloud-issued WOPI sessions,
and Whiteboard validates Nextcloud-issued JWTs. Their public Ingresses use the
direct edge. Collabora's administration and metrics paths remain restricted to
LAN and Headscale sources. Cilium restricts both backend ports to the Nextcloud
and HAProxy workloads; Linkerd separately authenticates Nextcloud's meshed
traffic and HAProxy's cluster-network connection.

Before enabling the Whiteboard deployment, run
`scripts/seed-nextcloud-collaboration-secret.sh` from the Balthasar directory
containing `vault-init.json`. The script adds the shared JWT property without
printing it or rotating the existing OIDC client secret. Both Nextcloud and the
official Whiteboard server consume independent Kubernetes Secrets synchronized
from that one Vault property.

Rollback by removing the supplemental values file and restoring the private
Ingress.

## Headscale OIDC

Headscale remains unchanged until both pilot applications are stable. When
enabled, restrict its Authentik provider to `headscale-users`, retain the static
administrator, and validate ACL identity mapping before migrating existing
users. Ordinary application users must not be added to this group. The staged
ExternalSecret and exact OIDC section are stored beside the Headscale
manifests; mount `client-secret` at `/etc/headscale/oidc/client-secret` rather
than putting it in the ConfigMap.

## Admission enforcement

The Ingress admission binding initially uses `Audit` and `Warn`. Before changing
it to `Deny`:

1. Confirm every current Ingress carries a valid exposure label.
2. Confirm all private Ingresses use the canonical RFC1918 plus
   `100.64.0.0/10` allowlist.
3. Confirm Cloudflare-edge Ingresses use the committed Cloudflare source list.
4. Confirm all public Ingresses carry explicit approval and edge labels.
5. Inspect API-server audit warnings for at least one normal deployment cycle.

Make the Deny transition as a separate commit so it can be reverted without
rolling back Authentik.

## Acceptance and rollback checks

- A cellular client resolves direct hosts to the WAN IPv4, receives a valid
  certificate, and completes OIDC without a VPN.
- Invitation reuse, email changes, expired links, arbitrary redirects, and
  cross-application group access are rejected.
- Removing an application group blocks the next authorization.
- Disabling an Authentik user revokes sessions without deleting application
  data.
- Harbor has no public DNS and rejects a forced public Host-header request.
- Direct origin requests for Cloudflare-only hosts are rejected.
- HAProxy, Authentik server/worker, PostgreSQL primary, and node failure tests do
  not remove the identity service.
- No secret value appears in Git, rendered manifests, Kubernetes events, or
  centralized logs.
