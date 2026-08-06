# Authentik

The Argo CD application deploys Authentik `2026.5.6` with two server pods and
two worker pods. PostgreSQL is provided by `pg-platform`; the chart's bundled
PostgreSQL and remote-cluster service account are disabled.

## Required Vault data

Create `kv/apps/identity/authentik` with:

- `secret-key`: a stable random value of at least 60 characters
- `postgresql-username`: `authentik`
- `postgresql-password`: a random value no longer than 99 characters
- `smtp-username`: the dedicated Mailgun SMTP username
- `smtp-password`: the dedicated Mailgun SMTP password
- `oidc-immich-client-secret`: the same independent random value stored in the
  Immich identity configuration
- `oidc-nextcloud-client-secret`: the same independent random value stored at
  `kv/apps/productivity/nextcloud-identity`
- `oidc-headscale-client-secret`: the same independent random value stored at
  `kv/apps/other/headscale-identity`
- `oidc-jellyfin-client-secret`: the same independent random value stored at
  `kv/apps/media/jellyfin-identity`

The namespace-local `harbor-pull-creds` Secret is populated from the existing
shared Vault entry at `kv/apps/productivity/harbor-pull-creds`. No dedicated
Authentik Harbor account or Vault entry is required.

The Authentik image is mirrored from `ghcr.io/goauthentik/server:2026.5.6` to
`harbor.rcrumana.xyz/mirror/goauthentik/server:2026.5.6` with digest
`sha256:f624d5b44c3f68441bce720b091b3c486e7f557b2fcf5027bccc857a21291a1c`.

The chart-generated public/direct Ingress initially carries the canonical
private source allowlist. Remove that one annotation only after the private
bootstrap, SMTP, passkey, recovery-code, and rollback checks have passed. The
separate `/if/admin/` Ingress must remain private.

## Bootstrap boundary

The mounted blueprints create the brand, authorization groups, client-only
invitation enrollment, passkey/TOTP/recovery-code setup, passkey-first login,
MFA recovery, and the Immich/Nextcloud/Headscale OIDC providers. Invitation
enrollment also confirms the fixed email address for account recovery and OIDC
claims. Normal authentication is passkey-first, with password plus TOTP, email
OTP, or a static recovery code available as progressively weaker fallbacks.

Client invitations are created per recipient in the admin UI with a 72-hour
expiry, `single_use: true`, and exactly this fixed data:

```yaml
email: person@example.com
```

The enrollment policy assigns the complete non-administrative client bundle;
invitation authors cannot select groups. It rejects extra fixed-data fields,
duplicate email addresses, changes to the fixed invitation email, reserved or
duplicate usernames, and usernames that are unsafe across downstream clients.
New client identities are placed under `users/clients`. See
`docs/client-identity-operations.md` for the operator procedure and
`docs/client-onboarding.md` for the user handoff.
