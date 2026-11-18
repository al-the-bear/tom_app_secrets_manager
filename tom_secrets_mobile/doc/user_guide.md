# Tom Secrets Manager — mobile app user guide

This guide is for the person who uses the Tom Secrets Manager on an iPhone,
an iPad or an Android phone or tablet: to look up and copy logins, edit
entries and generate passwords, with the vaults the desktop app keeps on
GitHub. It goes task by task; the labels in quotes are the ones the app
shows.

## Contents

- [What the phone keeps](#what-the-phone-keeps)
- [Installing](#installing)
- [Setting the phone up](#setting-the-phone-up)
- [Unlocking and locking](#unlocking-and-locking)
- [Finding and copying a login](#finding-and-copying-a-login)
- [Editing](#editing)
- [Staying current](#staying-current)
- [Settings](#settings)
- [Troubleshooting](#troubleshooting)

## What the phone keeps

The vaults stay on GitHub. When you unlock, the phone fetches them into its
memory; when it locks, they are gone from it. The phone keeps only what
opens them: the key files, the repository keys and a GitHub token of its
own, in the iOS keychain or the Android keystore, and — once you unlocked
with the master password — the vault's key behind Face ID, Touch ID or your
fingerprint. The master password itself is never stored.

So the phone needs a connection to unlock. System vaults (the ones the fleet
reads) are shown but read-only here. iOS fills nothing into other apps: you
copy a login from this app and paste it.

## Installing

The app is installed without an app store. On Android, install the APK from
`tom_binaries` (allow installing from that source when Android asks). On an
iPhone or iPad, build it from Xcode onto the device under your free Apple
personal team; such a build runs for 7 days and is installed again then. Two
days before, the app shows "This build stops starting on *date*: install it
again from Xcode".

## Setting the phone up

The first screen is "Set up Tom Secrets Manager".

**"Pair with a desktop"** (the usual way):

1. On the desktop app, open **Pairing** and choose **"Pair a device"**. It
   shows a code, the addresses it listens on and a QR code.
2. On the phone, type "This device's name" (e.g. `iphone`), then either:
   - **"Scan the desktop's code"** and point the camera at the QR code: it
     fills the address (the one in the phone's network) and the code. The
     camera is asked for the first time; or
   - type the "Code". On the same network as the desktop that is enough:
     the phone finds it. Over the VPN type the "Address" too (one of the
     desktop's, with its port, e.g. `10.8.0.2:47900`).

   Then **"Pair"**. iOS asks once whether the app may find devices on the
   local network: allow it.
3. On the desktop, tick the vaults the phone gets — the primary must be
   among them — and paste "A GitHub token for this device": a separate
   fine-grained token with read and write access to the vault repository,
   so you can revoke the phone alone. "Pair *name*" sends them.

**"By hand"**: for a primary without a key file or outer encryption, type its
location (`github:owner/repository/primary.kdbx`) and a GitHub token, then
**"Set up"**. A primary with a key file or an outer encryption needs the
pairing.

Then the unlock screen asks for the master password, once.

## Unlocking and locking

The first unlock asks for the master password. After it, the phone keeps the
vault's key behind Face ID, Touch ID or your fingerprint, and every later
unlock asks only for that — the prompt appears at once on the unlock screen.
A changed fingerprint or face enrolment, or a master password changed on
another device, makes the phone ask for the password again.

The phone locks:

- with the lock button at the top;
- after it was in the background longer than the lock timeout (30 seconds by
  default);
- when the app is closed.

If a change could not be written to GitHub yet, the lock button asks: "Write
now" tries again, "Discard" drops it (the phone keeps no copy).

## Finding and copying a login

On a phone, **Vaults** lists the vaults, each with what it is ("read-only on
this device: a system vault"), when it was fetched and the changes not yet
written. Tap a vault for its entries, an entry to open it. **Search** looks
in every vault by title, user name, URL and key.

On a tablet the list and the entry stand side by side; on a wide tablet in
landscape the desktop's tree, list and entry are shown.

A one-time code (TOTP) is added in the entry's "One-time code" section:
paste the `otpauth://` URI or the secret, or **"Scan a QR code"** the
service shows when you switch on two-factor sign-in there.

The copy buttons beside the user name, password and the one-time code put
the value on the clipboard. It does not go to your other Apple devices, and
it is cleared after the clipboard timeout (30 seconds by default). Android 13
and later hide it from the clipboard preview.

**Generator** makes a password for something outside the vaults and copies
it.

## Editing

Entries of your personal vaults are edited as on the desktop: the fields,
the password generator, the one-time code, tags and notes. A new entry comes
from the **+** on a vault's entry list. Each save is written to GitHub at
once; when another device changed the vault meanwhile, both changes are
merged, and a change both made to the same field shows under "conflicts to
settle" on the Vaults list.

System vaults are read-only on the phone: change them on a desktop.

Without a connection a save is kept in the app's memory, and the vault shows
"1 change not written to GitHub". The next time the app reaches GitHub it
writes it, merged with what other devices changed meanwhile. Until then the
change exists only in the running app: locking asks "Write now" (try again)
or "Discard".

## Staying current

While the app is open and unlocked it looks on GitHub for changes every few
minutes (15 by default), when you come back to it, and when you pull a list
down or tap the sync button at the top. Nothing happens while the app is
closed.

## Settings

- **"Unlock with Face ID"** (or Touch ID, your fingerprint): on by default.
  Turned off, the key kept behind it is forgotten and every unlock asks for
  the master password.
- **"Look for changes on GitHub every"**: 5, 15, 30 or 60 minutes.
- **"Lock in the background after"**: at once, 30 seconds, 1 or 5 minutes.
- **"Clear the clipboard after"**: 15, 30, 60 or 120 seconds.
- **"This device"**: its name and the primary vault.
- **"Set this device up again"**: locks and goes back to the setup screen (to
  pair again, e.g. after the keys were rotated on the desktop).

## Troubleshooting

- **"no connection: the vaults are only on GitHub"**: connect to the
  internet; the phone has no copy to open.
- **"GitHub refused the token"**: make a new token for this phone on GitHub
  and pair again, or set it up by hand.
- **"Wrong code: the desktop closed its pairing window"**: open a new pairing
  window on the desktop and type its new code.
- **"The desktop declined"**: nothing was received; pair again and choose the
  vaults on the desktop.
- **The master password is asked although Face ID is on**: the enrolment
  changed or the password was changed elsewhere; type it once and Face ID is
  used again.
