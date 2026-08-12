# Client onboarding

This guide explains how to activate your account and connect your devices. Existing VPN software can remain enabled because these services use normal encrypted HTTPS connections.

You will receive two separate invitations:

1. An Authentik invitation for the dashboard and most hosted applications.
2. A Vaultwarden invitation for the password vault.

The links are personal, time-limited, and intended only for the email address
that received them. Do not forward either invitation.

## Set up Vaultwarden

Vaultwarden is intentionally independent from Authentik. Open its separate
email invitation and create a distinct master password. The master password
encrypts your vault and cannot be recovered under any circumstances, even by an adminstrator.

Use `https://vault.rcrumana.xyz` as the server address in Bitwarden-compatible
browser extensions, desktop applications, and mobile applications. After the
account is active:

1. MFA is optional but recommended. Enable Vaultwarden-native MFA using TOTP or WebAuthn. (I use EnteAuth which is pretty excellent)
2. Store its recovery material outside the vault.
3. Turn on autofill if desired (I use it)
3. Test a complete logout and login before importing important credentials.

Public registration is disabled. Only the exact email address in a valid
operator-issued invitation can create an account.

## Set up Authentik

Open the Authentik invitation next. Ideally during enrollment you'll put all generated credentials directly into vaultwarden, otherwise there is no way to retrieve them. During enrollment you will:

1. Choose a username of 3-32 characters. It must begin with a lowercase letter
   and may contain lowercase letters, numbers, periods, underscores, and
   hyphens.
2. Enter your display name.
3. Create a fallback password of at least 12 characters.
4. Verify the invited email address.
5. Register a passkey.
6. Confirm the email one-time-code method.
7. Add the displayed TOTP secret to Ente Authenticator or another authenticator application.
8. Save the ten recovery codes.
9. For autofill you'll need to use custom fields titled "uidField" and "current-password" to get autofill working, or just use the extension/your passkey when prompted.

Store the fallback password and recovery codes somewhere safe, preferrably backed up. Anything in the vault is unrecoverable if the master password is lost.

Normal Authentik login uses this order:

1. Passkey
2. Fallback password and authenticator-app code
3. Fallback password and email code
4. Fallback password and recovery code

After enrollment, open the client dashboard at
<https://dashboard.rcrumana.xyz>.

## First application logins

The dashboard links to each available service:

- **Immich:** choose the Authentik/OAuth login. For the mobile application, set
  the server to `https://immich.rcrumana.xyz` and complete the browser login.
- **Nextcloud:** normal web login redirects to Authentik. Desktop and mobile
  clients should use `https://nextcloud.rcrumana.xyz` as the server address and
  complete the browser authorization.
- **LibreChat:** choose **Continue with Authentik**. Your account is created on
  first login.
- **Jellyfin:** use Authentik in a browser. Television and streaming clients can
  display a Quick Connect code that you approve from an already authenticated
  Jellyfin browser session.
- **Jellyseerr:** sign in through Jellyfin and approve its Quick Connect code.
- **HyperMind and Uptime Kuma:** opening the dashboard link uses the existing
  Authentik session; there is no separate application password.

An application might take a short time to create its local profile on the first
visit. Subsequent visits should be immediate.

## Recovery and support

If an Authentik login method is unavailable, select another enrolled method on
the login page. Authentik password recovery requires access to the verified
email address plus an existing passkey, TOTP device, or recovery code.

If the Vaultwarden master password and all local unlock methods are lost, the
personal vault cannot be decrypted. This is why its recovery material must be
stored independently.

For a failed or expired invitation, unexpected application access, or a lost
device, contact the operator through the same trusted channel used to arrange
the invitation. Never send authentication secrets while requesting help.
