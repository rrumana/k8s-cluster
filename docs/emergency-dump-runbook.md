# Emergency Dump Runbook

This guide explains how to create the emergency dump that copies important
cluster data to `/NAS/dump`.

The dump can take a while. That is normal.

## Before You Start

- Use Ryan's PC.
- Make sure the PC is on and connected to the home network.
- Do not close the terminal while the dump is running.
- Do not press `Ctrl+C` while the dump is running.
  `Ctrl+C` stops the script.

## Open The Terminal

Press `Windows` + `Enter`.

The terminal should open in:

```text
/home/rcrumana
```

## Paste The Command

On this PC, paste into the terminal with `Ctrl+Shift+C`.

Paste this exactly:

```bash
cd /home/rcrumana/Dev/github/k8s-cluster
sudo ./scripts/emergency-cluster-dump.sh
```

Then press `Enter`.

## If A Password Is Requested

The terminal may ask for the password for this PC user account.

Type the password and press `Enter`.

While typing the password, the screen may appear to show nothing. That is
normal.

## What The Script Does

The script copies important data from the cluster to:

```text
/NAS/dump
```

This includes:

- readable cluster secrets
- Nextcloud files
- Immich originals
- Vaultwarden exports
- cluster configuration notes

## What You Should See

Early in the run, the terminal should print messages like:

```text
[emergency-dump] checking cluster access
[emergency-dump] checking Vault readiness
This dump may take a while.
```

Later, it should print progress messages for each app.

## Wait For The Completion Message

Leave the terminal alone until it prints a final message.

Successful completion will end with something similar to:

```text
[emergency-dump] dump completed
Files located at /NAS/dump
Instructions for connecting new devices are in /NAS/dump/connect-device.md
```

It may also say:

```text
[emergency-dump] dump completed with warnings
```

That still means the dump finished. Some parts may have failed, but useful data
may still be present in `/NAS/dump`.

## After It Finishes

Open the dump folder at:

```text
/NAS/dump
```

Start with:

- `/NAS/dump/README-FIRST.txt`
- `/NAS/dump/connect-device.md`

## If It Completes With Warnings

Still check `/NAS/dump` first.

If more detail is needed, look at:

- `/NAS/dump/last-success.json`
- `/NAS/dump/_infra/app-status.tsv`
- `/NAS/dump/_infra/failures/`

## If The Script Stops Early

If the terminal shows an error and never prints a completion message:

1. Leave the terminal window open.
2. Take a photo of the terminal, or copy the full error text.
3. Ask a technical helper to review the error.

If a partial dump was created, it may still exist under `/NAS` with a name that
starts with:

```text
.dump-staging-
```
