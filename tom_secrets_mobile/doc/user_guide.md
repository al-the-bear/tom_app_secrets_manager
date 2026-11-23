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
- [Vaults in Files](#vaults-in-files)
- [Staying current](#staying-current)
- [Autofill on Android](#autofill-on-android)
- [Health](#health)
- [Shares](#shares)
- [Settings](#settings)
- [Troubleshooting](#troubleshooting)

## What the phone keeps

The vaults stay on GitHub. When you unlock, the phone fetches them into its
memory; when it locks, they are gone from it. The phone keeps only what
opens them: the key files, the repository keys and a GitHub token of its
own, in the iOS keychain or the Android keystore, and — once you unlocked
with the master password — the vault's key behind Face ID, Touch ID or your
fingerprint. The master password itself is never stored.

So the phone needs a connection to unlock (a vault you keep in Files, such
as iCloud Drive, is read from there instead). System vaults (the ones the fleet
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

**Through a relay server.** When the phone is neither on the desktop's
network nor on the VPN, the pairing can go through a relay server: on the
desktop choose it under "Also through a relay" before "Pair a device". Its
QR code then names the relay; scanning it fills the "Relay" field
(`tsm:https://…`), or type it, and tap "Pair". No token is needed for the
pairing itself; the desktop includes the GitHub token the phone uses for
the vaults. A magic-wormhole server (`wormhole:ws://…`, for example the
public `wormhole:ws://relay.magic-wormhole.io:4000/v1`) works the same way.

**Through a GitHub repository.** When the phone is neither on the desktop's
network nor on the VPN, the pairing can go through one of your vault
repositories on GitHub: on the desktop choose it under "Also through a
relay" before "Pair a device". Its QR code then names the relay; scanning it
fills the "Relay" field (`github:<owner>/<repo>`), or type it. Paste
**"This device's GitHub token for that repository"** — the phone needs one
anyway — and tap "Pair". With an address too, the address is tried first.
The phone keeps that token for the repository, so the desktop need not
paste one there; the pairing takes some seconds longer than over the
network.

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

Without a connection the unlock says "No connection: the vaults are only on
GitHub. The unlock is tried again by itself when the network is back." —
leave the screen open; it opens once the phone is online (for ten minutes).

If the unlock says a vault "needs N MiB of memory to open", its key
derivation is set heavier than this phone can afford: open it in the desktop
app and lower its memory setting.

If GitHub refused this phone's token (it expired, or you revoked it), tap
**"Set this device up again"** below the unlock form and pair again with a
desktop, which gives the phone a new token.

If a change could not be written to GitHub yet, the lock button asks: "Write
now" tries again, "Discard" drops it (the phone keeps no copy).

## Finding and copying a login

On a phone, **Vaults** lists the vaults, each with what it is ("read-only on
this device: a system vault"), when it was fetched and how big the fetch
was (on mobile data every unlock fetches the vaults again), and the changes
not yet written. Tap a vault for its entries, an entry to open it. **Search** looks
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

Shared vaults (vaults you share with other people) open on the phone like
your own. When a member is removed from one and the vault gets a new key,
the phone takes up the new key at its next unlock by itself, with your
member key. Creating a shared vault, opening someone else's and adding or
removing members happen in the desktop app.

**Attachments**: "Attach a file" in the entry's Attachments section takes a
file from Files; the share button beside an attachment hands it to another
app (to open or save it there). The shared copy is removed when you close
the share sheet (iOS) or at the next share (Android).

Without a connection a save is kept in the app's memory, and the vault shows
"1 change not written to GitHub". The next time the app reaches GitHub it
writes it, merged with what other devices changed meanwhile. Until then the
change exists only in the running app: locking asks "Write now" (try again)
or "Discard".

## Vaults in Files

A KDBX file of your own — in iCloud Drive, On My iPhone, or Google Drive and
the like on Android — can be a vault on the phone: **Settings › "Add a vault
from a file"**, pick the file, give the vault a name and type its password.
The phone reads the file into its memory when you unlock and writes it back
when you save; when it changed meanwhile (edited on the Mac, say), both
changes are merged. No copy is kept on the phone.

The vault is listed in your primary vault with its password, as every vault
is, under a name of this phone (`file:/tsm-document/<phone>/<file name>`):
your desktops and other phones list it, but cannot reach the file. Settings
lists every vault with where it is.

## Staying current

While the app is open and unlocked it looks on GitHub for changes every few
minutes (15 by default), when you come back to it, and when you pull a list
down or tap the sync button at the top. Nothing happens while the app is
closed.

When the desktop app runs a **guided rotation** of a vault's keys, the phone
takes the new key the next time it unlocks or refreshes, and the desktop's
Keys screen stops listing it as missing: open and unlock the app once while
the rotation is prepared. After the desktop switched, the phone opens the
vaults with the new key by itself. A phone that never took it opens no
vault re-keyed under it: set it up again by pairing.

## Autofill on Android

Turn it on under Settings › "Autofill service" › "Turn on" (the system's
choice of the autofill service opens; pick "Tom Secrets"). Then a login
field in an app or a browser offers "Unlock Tom Secrets Manager" (in the
keyboard's strip where the keyboard shows suggestions):

- with the app open and unlocked, your fingerprint (or the screen lock)
  confirms, and the logins of that app or site are offered;
- otherwise the app's unlock opens, fetches your vaults from GitHub, and
  offers the logins; nothing is kept once it closes. Without a connection
  it says so and fills nothing.

Only logins of your personal and shared vaults are offered, never a system
vault's. A login found by the app's name alone is marked "unverified app"
unless the site the login belongs to names that app (its Digital Asset
Links): check that it is the app you think. When you sign in with a login
the vaults do not hold, Android asks whether to save it in Tom Secrets: the
app opens and "A login to save" › "Review" shows it, to save as a new login,
update the existing one, or drop.

## Health

Settings › **"Health"** lists what in the vaults needs attention, as on the
desktop (its user guide has the details): weak, reused, old (one year by
default, "Old after" above the list), expiring and breached passwords, and
short SSH keys. A line opens its entry.

The **breach check** is on unless you turn it off: it asks Have I Been Pwned
with only the first five characters of each password's SHA-1 hash, so the
password never leaves the phone. It checks new and changed passwords at
once and all of them once a week, while the app is open and unlocked (a
phone runs no check in the background). Each run shows its result at the
bottom of the screen with **"Turn off breach check"**. "Exclude" next to a
breached login keeps it out of the check.

## Shares

Someone can share entries with you as an encrypted package (shares are sent
from the desktop app; its user guide has the details). Settings ›
**"Shares"** › **"Import a share…"**: paste the text, open the file, or
**"Scan QR code"** with the camera; a share under a passphrase asks for it.
The dialog says who sent it, and **"Import into…"** puts its entries into
the vault and group you pick.

Shares put into your inbox in a shared vault, or into your mailbox on the
relay server a shared vault names as its mailbox, are found when the phone
unlocks or refreshes: a banner names them ("1 entry from Bob") with
**"Open"**, and the Shares page lists them. **"Open…"** › **"Import
into…"** imports one and deletes it from the inbox or the relay;
**"Decline"** deletes it. Packages older than 30 days are deleted on their own.

## Settings

- **"Unlock with Face ID"** (or Touch ID, your fingerprint): on by default.
  Turned off, the key kept behind it is forgotten and every unlock asks for
  the master password.
- **"Look for changes on GitHub every"**: 5, 15, 30 or 60 minutes.
- **"Lock in the background after"**: at once, 30 seconds, 1 or 5 minutes.
- **"Clear the clipboard after"**: 15, 30, 60 or 120 seconds.
- **"Vaults"**: every vault with where it is (`github:…` or a file), and
  "Add a vault from a file".
- **"Health"**: the [Health](#health) screen.
- **"Check passwords against known breaches"**: the breach check, on by
  default.
- **"Shares"**: importing a share, and your inbox ([Shares](#shares)).
- **"Autofill service"** (Android): whether Tom Secrets fills logins in
  apps and browsers, and "Turn on".
- **"This device"**: its name and the primary vault.
- **"Set this device up again"**: locks and goes back to the setup screen (to
  pair again, e.g. after the keys were rotated on the desktop).

## Troubleshooting

- **"No connection: the vaults are only on GitHub"**: connect to the
  internet; the phone has no copy to open, and the unlock is tried again by
  itself.
- **"GitHub refused this device's token"**: "Set this device up again" below
  the unlock form, then pair again (the desktop gives a new token) or set it
  up by hand.
- **A banner says the GitHub token is due**: two weeks before it expires;
  make a new one and pair again before then (Settings › "Set this device up
  again").
- **"Wrong code: the desktop closed its pairing window"**: open a new pairing
  window on the desktop and type its new code.
- **"The desktop declined"**: nothing was received; pair again and choose the
  vaults on the desktop.
- **The master password is asked although Face ID is on**: the enrolment
  changed or the password was changed elsewhere; type it once and Face ID is
  used again.
