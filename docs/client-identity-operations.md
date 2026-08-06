# Client identity operations

This is the operator procedure for onboarding a normal client. It is not a
privileged-user or Headscale enrollment procedure.

Send `client-onboarding.md` to the client before creating invitations so the
client can prepare a passkey provider, authenticator application, and offline
place for recovery material.

## Preconditions

- Use the Authentik `admin` identity. Do not perform routine onboarding as
  `akadmin` or `rcrumana`.
- Confirm Authentik and its workers are healthy and SMTP is delivering mail.
- Confirm the email does not already belong to an Authentik or native
  application account unless account association is explicitly intended.
- Never collect or store the client's passwords, passkeys, TOTP seed, recovery
  codes, or Vaultwarden master password.

## Create the Authentik invitation

1. Open Authentik Admin and navigate to **Directory > Invitations**.
2. Create an invitation with the existing enrollment flow named **Rcrumana
   client invitation enrollment**.
3. Use a non-sensitive slug-style name that makes the invitation auditable.
4. Set expiration to 72 hours.
5. Enable **Single use**.
6. Enter exactly this custom data, substituting the invited address:

   ```json
   {
     "email": "person@example.com"
   }
   ```

7. Do not add `app_groups`, `attributes`, a username, or any other fixed-data
   field. The flow rejects additional fields.
8. Send the invitation through Authentik and confirm the background mail task
   completes successfully.

The flow assigns exactly these groups:

- `app-homepage-client`
- `app-hypermind`
- `app-immich`
- `app-jellyfin`
- `app-librechat`
- `app-nextcloud`
- `app-uptime-kuma`

It cannot grant `platform-admins` or `headscale-users`.

Usernames must match `^[a-z][a-z0-9._-]{2,31}$`, must be unique without regard
to case, and cannot use a reserved operational name. Invalid values produce a
specific message before the user is created.

## Create the Vaultwarden invitation

Vaultwarden is separate from Authentik because its master password is part of
the vault encryption boundary.

1. Connect through LAN or Headscale.
2. Open `https://vault.rcrumana.xyz/admin`.
3. Authenticate with the Vaultwarden administrator password.
4. Open **Users** and invite the same verified email address.
5. Confirm Mailgun accepted the message.

Public signups and organization-administrator invitations are disabled. Do not
save general configuration through the Vaultwarden administrator page because
`/data/config.json` would override the GitOps environment.

## Verify completed enrollment

After the client reports success, inspect the Authentik user:

- Active internal user under `users/clients`
- Email exactly matches the invitation
- Exactly the seven client groups listed above
- No `platform-admins` membership
- No `headscale-users` membership
- Passkey, confirmed email device, TOTP device, and recovery codes enrolled

Then have the client verify:

- Passkey login in a fresh private browser session
- Password plus TOTP fallback
- Dashboard access
- Immich, Nextcloud, LibreChat, Jellyfin, Jellyseerr, HyperMind, and Uptime Kuma
- No administrative role in any application
- Vaultwarden registration, native MFA, logout, and login

Do not pre-create native application accounts for a new client. OIDC applications
create their local profiles on first login; Jellyseerr inherits Jellyfin
identity. Vaultwarden is the intentional exception and uses its own invitation.

## Failed or abandoned enrollment

- Revoke or delete the unused Authentik invitation before issuing another.
- Remove an abandoned Vaultwarden invitation from the Users page.
- Do not reuse an invitation for another email address.
- Record completion and failures without recording invitation tokens or user
  secrets.

Account disabling and native-session revocation are handled by the separate
offboarding procedure; deleting an Authentik identity must never be treated as
authorization to delete application data.
