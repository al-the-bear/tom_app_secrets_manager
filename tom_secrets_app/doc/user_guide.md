# Tom Secrets Manager — desktop app user guide

This guide is for the person who uses the Tom Secrets Manager desktop app on
macOS, Windows or Linux: to keep passwords, tokens and notes, and to hand
secrets to the programs on their machines without writing them into files.
It goes task by task; the labels in quotes are the ones the app shows.

## Contents

- [The idea in one page](#the-idea-in-one-page)
- [Installing and first start](#installing-and-first-start)
- [The First run wizard](#the-first-run-wizard)
- [Unlocking and locking](#unlocking-and-locking)
- [The main window](#the-main-window)
- [The vault browser](#the-vault-browser)
- [System secrets](#system-secrets)
- [Approvals](#approvals)
- [Importing from 1Password and Enpass](#importing-from-1password-and-enpass)
- [Keys](#keys)
- [Pairing another device](#pairing-another-device)
- [Conflicts](#conflicts)
- [Settings](#settings)
- [Status](#status)
- [Troubleshooting](#troubleshooting)

## The idea in one page

- **Vaults** are KeePass (KDBX) files. They live on this computer or in a
  private GitHub repository, and any KeePass app can open them with their
  keys. A vault may carry an **outer encryption** (`.kdbx.tsmx`), so the
  repository holds nothing GitHub or anyone else can read.
- The **primary vault** holds your own secrets and the keys of every other
  vault: unlocking it with your **master password** opens them all.
- The **secrets service** runs in the background for your user. It holds the
  unlocked vaults and answers the programs on your machine (through the
  command line `tsm` and the client libraries). The app starts it, unlocks
  and locks it, and edits the vaults through it. Quitting the app leaves the
  service running.
- A program that asks for a secret for the first time waits for your
  **approval**: you allow it once, always, for a folder, or never.
- **Overlays** give one secret different values per host, platform or
  environment (for example a different database password in `prod`).

## Installing and first start

Download the archive for your platform from the release and unpack it (the
repository README's [Installing](../../README.md#installing) lists the
archives):

- **macOS:** move `Tom Secrets Manager.app` to `/Applications`. The app is
  ad-hoc signed, not notarised: open it the first time with Control-click ›
  Open, and confirm.
- **Windows:** unzip into a folder of your choice and start
  `tom_secrets_app.exe`. If SmartScreen says "Windows protected your PC",
  choose More info › Run anyway.
- **Linux:** unpack into a folder of your choice and start `tom_secrets_app`.
  The tray icon needs a desktop with an AppIndicator (StatusNotifierItem)
  host; without one, closing the window minimises it.

The app runs once per user: starting it a second time brings the open window
to the front. It registers itself to start at login (in the tray, without a
window) on its first start; switch that off under
[Settings](#settings) if you prefer.

Closing the window keeps the app in the tray (the menu bar on macOS). The
tray menu has "Open", "Lock" or "Unlock…", the number of approvals waiting,
"Quit the app (the service keeps running)" and "Stop the service".

The command line `tsm` comes inside the app (on macOS in
`Tom Secrets Manager.app/Contents/Resources/tsm/bin`, elsewhere in the app
folder's `tsm/bin`). Link it onto your `PATH` to use it from a shell.

## The First run wizard

On a machine that is not set up yet, the app opens "Set up Tom Secrets
Manager". Its steps are "The vault", "Protection", "This machine" and "Done".
At the top of the first step you choose:

- **"Set up the vault here"**: create your primary vault, or open one you
  already have; or
- **"Pair with another desktop"**: this machine gets its vaults and keys
  from a desktop that is already set up (see
  [Setting up by pairing](#setting-up-by-pairing)).

### Step 1: the vault

Choose **"Create a new vault"** or **"Open an existing one"**, and where it
is: **"On this computer"** or **"In a GitHub repository"**.

- **On this computer:** give the "Vault file" (or "Choose…" one; a new vault
  is suggested as `primary.kdbx`).
- **In a GitHub repository:** give the "Owner", the "Repository" and the
  "File in the repository". The repository must be private and have a first
  commit (create it with a README). Then "Enter a token…": a **fine-grained
  personal access token** for that one repository with Contents: Read and
  write. The app keeps it in this machine's keychain. "Check the repository"
  confirms the token sees the repository and shows when the token expires;
  when GitHub reports no expiry, "Set its expiry…" so the app can remind you
  before it runs out.

Then the **master password**, twice for a new vault ("Master password",
"The same again"; at least 10 characters). Nobody can recover it for you:
keep it where you keep your other recovery codes. When you open an existing
vault that has a key file, give the key file with the password.

Opening a vault with an outer encryption asks for its "Repository key
(base64)", typed or "From a file…".

### Step 2: protection

Both layers are optional, and each adds a key you must not lose: without it
the vault cannot be opened on another machine.

- **"Key file"**: a KeePass key file joins the master password; the vault
  opens only with both. It never goes to GitHub. "Save a copy…" puts a copy
  (`primary.keyx`) where you keep your recovery codes.
- **"Outer encryption"**: the file is encrypted once more under a repository
  key (`primary.kdbx.tsmx`). Choose the "Cipher": "XChaCha20-Poly1305
  (recommended)" or "AES-256-GCM". "Save a copy…" saves the repository key.
- **"Emergency sheet"**: "Print the emergency sheet…" or "Save it as a
  PDF…". The sheet lists your vaults, their repositories and formats, and
  every key file and repository key as a QR code; the master password line
  is left blank for you to write in. Keep it offline; if you save the PDF,
  print it and delete the file.

The app reminds you when these keys are due for rotation.

### Step 3: this machine

- **"This machine's name"**: how this machine appears to your other devices
  and in approvals (for example `laptop1`).
- **"Default environment (optional, e.g. prod)"**: the environment programs
  on this machine get when they name none.
- **"Serve only the primary vault"**: off, the machine serves every vault the
  primary lists.
- **"Lock"**: "When idle" after a number of "Minutes", or "Never on its
  own".
- **"Advanced"**: "Where the device settings' key is kept" (the keychain
  where there is one, else the vault; the keychain; the primary vault; a key
  file beside the settings).

"Set up this machine" writes the setup, starts the service and unlocks it.

### Step 4: done

The last step says what was set up and when its keys and GitHub token are
due, and offers the next things to do: "Import from 1Password or Enpass" and
"Pair another desktop". "Open my vaults" takes you to the main window.

### Setting up by pairing

On a desktop that is already set up, open **Pairing** and choose "Pair a
device": it shows an address and a code (see
[Pairing another device](#pairing-another-device)). On the new machine, in
the wizard's first step, choose "Pair with another desktop" and give:

- **"Its address"** as the other machine shows it, for example
  `192.168.1.20:47900`. On the same network leave it empty: the app finds the
  other machine by the code. Over a VPN, type the address.
- **"The code"**, for example `7-guitar-orbit`.
- **"This machine's approval link (optional)"**: a VPN or LAN address of
  this machine and a port, for example `10.8.0.6:47731`, never `0.0.0.0`.
  The other machine is told it and answers this one's approval prompts over
  the link at once. Left empty, this machine has no approval link.
- **"This machine's name"**.

Choose "Pair". While it says "Waiting for the other machine…", confirm on the
other machine what this one gets. The wizard then lists what it was given
(the vaults, the shared configuration, GitHub tokens); nothing is stored yet.
Type the "Master password of the primary vault", go on to "This machine",
and choose "Set up this machine". The Protection step is left out: the keys
come from the other machine.

## Unlocking and locking

When the service is locked, the app shows **"Unlock"**: give the master
password (and the key file, if the primary has one) and choose "Unlock".
When a program is waiting for the secrets, the screen says "A program on
this machine waits for the unlock", and a notification "Unlock the secrets"
appears while the window is closed.

To lock: the lock button in the top bar, Cmd+L (Ctrl+L on Windows and
Linux), or "Lock" in the tray menu. The service also locks by itself as
[Settings](#settings) say (when idle, after a longest unlocked time, or
never). Locking drops every open vault from the app's memory.

Other screens you may meet before unlocking:

- **"The service is not running"**: "Start the service".
- **"Service stopped"**: the service ended; start it again to go on.
- **"Take over the service"**: a service runs that this app holds no key
  for (it was started from the command line, or another admin took it
  over). Taking it over sends your master password to it; do it only on a
  machine you trust.

A vault with a password of its own shows "has a password of its own" in the
vault browser; "Open…" asks for it.

### Unlocking with Touch ID or Windows Hello

On macOS and Windows the app can keep the unlock of the primary vault under
the operating system's own check, and open the vaults with it instead of
the master password:

- **For this session:** choose "(c) idle or screen lock" as the service's
  lock mode in [Settings](#settings). The first unlock with the master
  password is kept; from then on the service locks when you are idle or
  lock the screen, and "Unlock with Touch ID" (or "Windows Hello") opens it
  again. It ends when the service stops or you choose "Lock completely" in
  the tray menu; then only the master password unlocks.
- **Saved:** tick "Remember the master password with Touch ID" when you
  unlock, or switch it on in Settings. The unlock then survives restarts of
  the service and the app. A saved unlock opens the vault even when you
  have forgotten the password, so on this machine you could set a new one;
  switch it off where that is not wanted.

What is kept is the vault's composite key (the key the master password and
key file make) and its repository key, never the password itself. When
there is one, the app asks for the check as soon as the unlock screen
appears; cancel it to type the master password instead.

The master password always works. The app asks for it once, and keeps the
unlock again afterwards, when:

- the vault's master password was changed (perhaps on another machine);
- a fingerprint or face was added or removed, or Windows Hello was set up
  again;
- the check is locked after too many attempts, or cannot be used (a remote
  session, a closed lid).

**On macOS before the app is signed by its developer team** (as now), Touch
ID is the weaker, gate-only form: it guards the unlock, but the unlock is
kept in the login keychain, where a program running as you can read it
without Touch ID. Settings say so. With Windows Hello the key exists only
after Hello has signed, so nothing without Hello opens it. **Linux has no
OS unlock**: the master password is the only way to unlock there.

## The main window

The rail on the left holds the screens: **Vaults**, **Environments**,
**Conflicts** (with the number of conflicted entries), **Clients** (with the
number of approvals waiting), **Keys** (with the number of keys due),
**Pairing**, **Import**, **Settings** and **Status**.

The top bar holds:

- **"Search every vault"** (Cmd/Ctrl+F);
- **"Tree"** and **"List"** (Cmd/Ctrl+1, Cmd/Ctrl+2);
- **"Vault-aware"** (system vaults show keys, overlays, bindings and
  readers; personal ones logins, URLs and TOTP) and **"Uniform"** (one
  column set for every vault);
- the sync state of the GitHub vaults, the approvals and keys-due badges, and
  the lock button.

Cmd/Ctrl+N makes a new entry, Cmd/Ctrl+S saves the entry being edited.

While a key is due, a banner names it: "Snooze" hides it until the next
reminder step, "Open Keys" goes to the [Keys](#keys) screen.

## The vault browser

### Tree and list

- **Tree** shows the groups of each vault, the entries of the chosen group
  and the chosen entry's details.
- **List** shows every entry, filtered by "Vault", "Type" and "Tag".

The vault's menu has "New group"; a group's menu "New group in it",
"Rename" and "Move…". "New entry" asks for a title and opens the editor.
Overlay groups (named `@host:…`, `@env:…`) are not shown as folders: they
appear as the entry's overlays.

Tick entries to act on several at once: "Move…", "Tag…", "Move to the
recycle bin", "Clear the marks".

A vault served from its offline copy is marked "offline copy:" with the
reason and its age, and opens read-only.

### A new vault

"New vault…" (under the vaults in the tree; also on the Environments and
Import screens) creates a further vault beside the primary:

- its **name** (the store name: lower-case letters, digits, `-` and `_`),
  its **kind** ("Personal" for your own passwords, "System" for the
  processes' secrets) and, for a system vault, **the environment it serves
  in** (`env`; every entry of the vault is bound in it; left empty, it
  serves in every environment);
- **where it lives**: "Beside the primary" (its GitHub repository or its
  folder), "Another GitHub repository" (`owner/name`, an optional folder,
  and its token when this machine's keychain has none, kept with the vault's
  entry in the primary) or "A file on this machine" (an absolute folder);
  the vault's place is shown below;
- its **keys**: "Generate the master password" (kept in the primary only,
  so the vault opens wherever the primary does) or one you type; a "Key
  file": "None", "The primary's key file" or "A new key file";
- "Outer encryption (.kdbx.tsmx)": under "A new repository key" or the key
  the repository's other vaults use, with its cipher.

"Create" has the service write the new file where it lives and list the
vault with its keys in the primary; every machine that opens the primary
serves it from then on. Save copies of a new key file and repository key,
and replace your emergency sheet.

### The entry editor

An entry is a "Login", an "API token", a "Secure note" or an "SSH key"
(imported entries can also be a certificate or a PGP key). The editor holds:

- "Title", "User name", "Password" (or "Token");
- the password generator (the dice button, "Generate a password"): the
  length, "Lower case (a–z)", "Upper case (A–Z)", "Digits (0–9)",
  "Symbols", "Leave out look-alikes", and the strength in bits; "Use" puts
  it in the field;
- "URLs" ("Add a URL");
- "One-time code (TOTP)": an `otpauth://` URI or a base32 secret; the
  current code is shown with its countdown, with "Copy the code";
- "Notes";
- "Custom fields" ("Add a field"; each field can be protected);
- "Tags and expiry": tags separated by commas, and "Expires" with a date;
- "Attachments": "Attach a file", "Save as…", "Remove";
- "How clients name it": the "Path" and the "Key (tsm.key)", the name a
  program asks for (lower-case dotted names, for example
  `telegram.bot_token`, unique in the vault);
- "Overlays…" (see [System secrets](#system-secrets));
- "History": earlier versions, each with "Restore".

"Save" (Cmd/Ctrl+S) writes the entry; "Discard" drops your edits.

Protected values are masked. "Reveal for 30 seconds" shows one; "Copy"
copies it to the clipboard, which is cleared after 30 seconds.

When the entry changed elsewhere while you edit, the editor says so; your
unsaved edits are saved over it field by field, or "Discard my edits".

### SSH keys

An "SSH key" entry holds a private key as its attachment, with a
`KeeAgent.settings` attachment beside it, so KeePassXC's SSH agent finds the
key in the same file. Its "SSH key" section shows the key's type and bits,
the attachment's name, the fingerprint (`SHA256:…`) and the public key
(the `authorized_keys` line, with "Copy the public key"). The section offers:

- "Generate an Ed25519 key": the key to use by default, written as
  `id_ed25519` and commented with the entry's title;
- "RSA 4096 (for a tool that needs RSA)": an RSA key of 4096 bits, written
  as `id_rsa`;
- "Choose a key file…": a private key file you have (OpenSSH, PEM or
  PKCS#8); a file without a private key is refused.

A key already there is replaced only after you confirm; the old key stays in
the entry's history. The "Passphrase" field holds the key's passphrase,
needed only when the key file is encrypted. An encrypted OpenSSH key still
shows its public key; an encrypted PEM key hides it (`ssh-keygen -y -f
<file>` prints it with the passphrase).

Vaults from before SSH keys had their own type kept such keys as secure
notes. When the app loads a vault it can write, it turns every note (or
KeePassXC entry) whose attachment is a private key into an "SSH key" entry
and saves the vault; the note as it was stays in the entry's history.

### The ssh-agent

The secrets service is an ssh-agent: `ssh`, `git`, `scp` and `rsync` sign
with the vaults' SSH keys through it, and no private key file is needed on
the machine. Switch on "ssh uses the ssh-agent" under Settings ›
Integrations (or run `tsm integrations install ssh`): it writes
`IdentityAgent` with the agent's socket into `~/.ssh/config`, for every host
(`Host *`) or the host patterns you give. By hand, `tsm status` names the
socket (`agent`; on Linux and macOS `agent.sock` in the service's runtime
directory, on Windows the pipe `\\.\pipe\tsm-ssh-agent`):
`export SSH_AUTH_SOCK=<the agent socket>`, or `IdentityAgent` in
`~/.ssh/config`, where on Windows every backslash is doubled
(`IdentityAgent \\\\.\\pipe\\tsm-ssh-agent`): ssh's config reader takes a
backslash as an escape.

The "SSH key" section says whether the agent serves the key ("Served by the
ssh-agent."), and if not, why: for example the key is encrypted and its
passphrase is empty, or KeePassXC's agent settings do not allow it. "Confirm
every signature the agent makes with it" asks you each time the key signs
(KeePassXC's "require confirmation", which it reads too). A vault's menu in
the tree has "Confirm every SSH signature" for all its keys.

The first time a program signs with a key, the approval prompt asks you
(see [Approvals](#approvals)). While the service is locked, a signature waits
for you to unlock it.

### git's credentials

With "git asks Tom Secrets Manager for credentials" switched on under
Settings › Integrations (or `tsm integrations install git`), git asks the
vaults for the password or token of the host it talks to: the login whose
URL has that host. The first time, **"A tool asks for a login"** lists the
logins of the host: pick one, then "This time", "Always this login" (git
gets it from then on without asking) or "None". When git saw a new
password work, it is offered to the app as a proposal; a password the
vaults hold already is not.

## System secrets

System secrets are the secrets programs ask for: API tokens, database
passwords, keys. A program names one by its key (`tsm.key`) or its path.

### The vault-aware view

With "Vault-aware" on, an entry of a system vault shows its key, the
dimensions it is bound in (for example `bound env:prod`) and which clients
read it and when; an entry of a personal or shared vault shows its login,
URL and TOTP.

### The overlay editor

"Overlays…" in the entry editor opens **"Overlays of"** the entry: a matrix
with the shared entry on top, then for each dimension (host, platform,
environment) one row per value, each with the value it gets and where it
comes from. Choose the field to show with "Field".

- Click a row without a value of its own ("click to give it its own value")
  to create an overlay: a copy of the shared entry for that value, which you
  then edit in place.
- An overlay's menu has "Remove the overlay".
- "Clients name it" shows the reference to copy.

**"Which value does … get?"** answers what a program would receive: type the
qualifiers, for example `[env:prod,host:server1]` (dimensions you leave out
take their default), and choose "Resolve". It shows "1. The request",
"2. The candidates" (each kept with its rank, or dropped with the reason)
and "3. The answer": the shared entry, an overlay, another file, no entry,
or "Ambiguous" when two entries rank equal (the service then refuses the
request).

### Environments

**Environments** puts the keys of every environment's file side by side, one
column per file this machine serves. "Filter keys" narrows the rows and
"Field" chooses the field shown. A cell is edited in place; an empty cell's
"add" creates the entry in that file. Values are masked, with "Reveal for 30
seconds" and "Copy".

Vaults the primary lists but this machine does not serve appear under "Not
served on this machine": "Open" one to edit it here; its saves are written
to its location, and "Close" puts it away again.

A file the configuration names that the primary lists no keys for shows
"no keys"; click it to create it as a system vault in its environment. "New
vault…" creates another (see [A new vault](#a-new-vault)).

## Approvals

### The prompt

When a program asks for secrets for the first time, **"A program asks for
secrets"** opens on top of the window (and a notification "Approve a
request" while the window is closed). It shows:

- **"Who asks"**: the executable (or the interpreter and script), its
  arguments, its folder, what started it, and whether it connected from
  another machine;
- **"Which secrets"**: the references and the entries they resolve to;
- **"Your answer"**: "Once", "Always", "Always for this folder" (with
  "Everything below this folder") or "Never". A lasting answer also
  "Covers" "This reference", "Store" or "All", and can be pinned: "Only
  while the program file is unchanged (pinned)".

**A tool asks for a login** is git's credential helper (see [git's
credentials](#gits-credentials)): pick one of the host's logins and answer
"This time", "Always this login" or "None".

"Allow" (or "Refuse" for Never) answers; "Later" leaves the request waiting
under Clients. A program that asked for a client token gets one with an
"Always" answer and is known by it from then on. "Only when started by …"
makes a lasting answer hold only while the program is started by the same
parent (for example the `ssh` that `git` starts).

**An SSH signature** (the ssh-agent) opens "A program wants to use an SSH
key": "Which SSH key, for what" names the key and its fingerprint, "For
host" the server (its names from your `known_hosts`, and its host key), and
the "Purpose": "to log in", "to sign a git commit or tag" or "to sign". A
lasting answer "Covers" "This key", "Its vault's keys" or "All keys", and
"Only for this host" (on by default) keeps it to that server.

**"Confirm an SSH signature"** asks about one signature only, answered
"Allow this signature" or "Refuse it": for a key (or vault) that confirms
every signature, and for a signature asked over a forwarded agent (`ssh -A`,
a program on another machine using your key). A forwarded agent gets a key
only with a grant that allows forwarding for that key and host, made under
Clients › Pre-approve; without one it is refused without asking.

### The Clients screen

Its tabs:

- **"Approvals"**: the requests waiting; "Answer…" opens the prompt.
- **"Allow list"**: every grant, of every host or one ("Every host"), with
  what it covers, when it was last used, and "Revoke".
- **"Pre-approve"**: "Pre-approve a client for a host" before it asks:
  the "Host", "Who" (an executable, an executable started by a parent, a
  script with its interpreter, a folder or an interpreter, by path), the
  "Secret" (a reference such as `telegram.bot_token`, `store <name>`, or
  `all`), "Allow" or "Never", and pinning; "Add the grant". It applies once
  that host reads the vault again. "For the ssh-agent (SSH keys)" makes it a
  grant for the agent: the "Keys" (a key entry's reference, `store <name>`
  or `all`), "Only for these hosts" (their host key fingerprints, as
  `ssh-keygen -lf` prints them) and "Also over a forwarded agent", which
  needs one key and its hosts; every forwarded signature is still
  confirmed.
- **"Approval code"**: see below.
- **"Audit log"**: who read what and with which outcome, filtered by time
  ("Last 1 h" to "Last 30 days"), host, outcome, client and reference. An
  SSH signature names its key, the host and whether it was forwarded.

### Approval codes

A program waiting on a machine where no app is attached (a server, a
terminal session) shows a ten-character **approval code**. On your desktop,
under Clients › "Approval code": give the "Host that shows the code", the
"Approval code" and your answer, and "Make the token". Type the token on
that machine:

```text
tsm approve <token>
```

A lasting answer also needs who asks and the secret, as that machine shows
them (`tsm approvals`). The code is valid for a few minutes (see
[Settings](#settings)).

## Importing from 1Password and Enpass

Open **Import** (also offered at the end of the First run wizard).

1. **"The export"**: export from 1Password 8 (File › Export, as 1PUX,
   recommended, or CSV) or from Enpass (File › Export, as JSON, recommended,
   or CSV, one vault per file), then "Choose the export…". The format is
   taken from the file extension; for a CSV, choose which app made it. For
   an Enpass CSV, name the Enpass vault the file holds. Keep the export
   outside every repository: it holds every password in plaintext.
2. **"Where each vault goes"**: for each vault of the export, the vault and
   the "Group (a/b/c)" it goes to; "Into a new vault…" creates the vault
   first (see [A new vault](#a-new-vault)). Tick "Import the archived items
   too (into an Archive group)" if you want them.
3. **"Preview"** shows what would happen without writing anything: the
   counts (added, updated, imported as conflicts, unchanged, left out, not
   imported), "What the format loses", the "Largest attachments" and every
   item. **"Import"** writes it and shows the report.

Importing the same export again updates what changed and skips the rest.
Afterwards, "Delete the export".

## Keys

**Keys** lists every key with a date, soonest first: the GitHub tokens, the
vaults' key files and repository keys, and this device's approver and
approval-link key pairs, each with its use, date and time left. The app only
reminds; a key is never rotated by itself. Reminders start some days before
a key is due (see "Rotation ages and reminders" below), then 7 days and 1
day before, and once a day once it is due; a notification comes once a day
while the app runs.

### Signing in with GitHub

"GitHub sign-in (this machine)", at the top of Keys, signs the machine in
with your own GitHub App instead of a token pasted per repository; the
service then renews the App's tokens itself (every 8 hours; a sign-in
unused for six months must be renewed with "Sign in again").

1. **Once, for all your devices:** register the App on GitHub ("Register on
   GitHub…" opens the page): "Repository permissions › Contents: Read and
   write", "Enable Device Flow" on, no webhook; install it on the vault
   repositories only. Enter its client id and "Save": it is kept in the
   primary vault, so every device knows it.
2. **On each device:** "Sign in with GitHub" shows a code (also put on the
   clipboard) and opens github.com/login/device; enter the code there, on
   any device. The section then says "Signed in with the GitHub App as …".
   A headless machine signs in with `tsm login`.

"Use a personal access token instead" signs the machine out; it uses the
tokens pasted for the repositories again. Keep a pasted token on a machine
you may want to cut off alone: revoking the App's authorization on GitHub
signs out every device at once, while a pasted token is deleted for one
device. The Pairing screen shows how each device reaches GitHub, and
"Revoke" says what to do on GitHub for it.

### Renewing a GitHub token

"Renew…" on a token opens "Renew the GitHub token for" the repository:

1. Choose "Expires in" and "Open GitHub's new-token page": the page opens
   filled in (name, description, owner, expiry, Contents: Read and write).
   GitHub cannot preselect the repository: under Repository access choose
   "Only select repositories" and select it.
2. Paste "The new token" and "Check and save": the service checks that it
   sees the repository and may write to it, and keeps it where the old one
   was.
3. "Open GitHub's token list" and delete the old token.

### Rotating a vault's keys

"Rotate…" (on a vault's key row, or under "Rotate a vault's keys") opens
"Rotate the keys of" the vault:

- "New master password", typed or generated;
- "Key file": "Keep it as it is", "A new key file (replaces the old one, or
  adds one)" or "Remove the key file";
- for a vault with an outer encryption, "New repository key" (every vault of
  the repository under the same key is re-encrypted) and the "Outer
  cipher";
- "Add outer encryption…" or "Remove outer encryption…" moves the vault
  between `.kdbx` and `.kdbx.tsmx` (only on a machine that serves it).

"Rotate" writes the new keys into the primary, then saves the vault under
them, and cuts the GitHub history so no commit keeps the file under the old
keys. Then save copies of the new key file and repository key, and replace
your emergency sheet ("Print the emergency sheet…", "Save it as a PDF…").
After rotating the primary's key file or repository key, your other devices
need them: pair them again or copy the keys by hand; until then they open
their offline copy only.

If a re-keyed save failed, a banner says the rotation is not finished;
"Finish the rotation" completes it.

"Due date…" sets when a vault's keys are due.

### This device's key pairs

"Rotate…" on this device's approver or approval-link key opens "Rotate this
device's key pairs": both pairs are replaced together, what the old approver
key signed is signed again, and every paired host is told. The old link key
keeps working for 14 days for the hosts not reached yet.

Some rows show their action as "Not available in this version yet".

### Rotation ages and reminders

"Rotation ages and reminders (this machine)" sets the days before a GitHub
token or any other key that reminders start, and the rotation ages of the
key pairs, the primary's keys and the other vaults' keys. "Save" keeps them.

## Pairing another device

Pairing brings another of your machines in: it gets the vaults you choose
with their keys, and the two approve for each other.

On the machine that is set up, open **Pairing** and choose **"Pair a
device"**. The app opens a pairing window for five minutes and shows the
code, the addresses it listens on, a QR code for a phone or tablet to scan
(it holds the addresses and the code) and the time left; the code works
once.
On the same network it is announced, so the other machine needs the code
only; over a VPN it needs the address too. The first time, macOS or Windows
Defender Firewall asks whether the app may accept connections: allow it.

On the other machine, use the First run wizard's "Pair with another desktop"
([Setting up by pairing](#setting-up-by-pairing)); a phone or tablet uses the
mobile app's "Pair with a desktop", scanning the QR code ([mobile user
guide](../../tom_secrets_mobile/doc/user_guide.md#setting-the-phone-up)).
Tick the primary for a phone: it is set up from it. A phone needs a GitHub
token of its own; it approves nothing and gets no approval link. A vault a
phone keeps in its Files (`file:/tsm-document/<phone>/…`) is listed in the
primary too; a desktop shows it as not reachable, as another machine's file
vault. When it has
proved the code, this machine shows "*name* proved the code. Choose what it
gets:":

- tick each vault it gets (the primary included or not), each with its key
  file and repository key;
- tick "The shared configuration (dimensions)";
- paste "A GitHub token for this device (optional)" per repository: make a
  separate fine-grained token for that device. This machine's own token is
  never sent.

"Pair *name*" sends it; "Decline" sends nothing. "Close the pairing window"
ends it early; leaving the screen or locking closes it too.

**"Paired devices"** lists each device with its platform, when it was
paired, the key ids it received and its key-pair dates. **"Revoke"** ends
the mutual approvals. The device keeps the keys it received: if it is lost
or no longer trusted, rotate those keys on the [Keys](#keys) screen (the
confirmation names them).

## Conflicts

When two devices change the same field of an entry differently, the merge
keeps the newer value and records the conflict; the other value is in the
entry's history. **Conflicts** lists the entries with fields to settle.
"Resolve…" shows each field with both values (masked when protected): keep
one side or write the value, and confirm. The last settled field clears the
conflict.

## Settings

Each setting says whose it is.

**This machine** (kept by its service):

- "Serve every file the primary vault names", or only the ones you pick;
- "Default environment";
- "The service locks": "(b) when idle" after "Idle minutes before it locks",
  "(a) never", or on macOS and Windows "(c) idle or screen lock" with Touch
  ID or Windows Hello ([Unlocking with Touch ID or Windows
  Hello](#unlocking-with-touch-id-or-windows-hello)); "Remember the master
  password with Touch ID"; "Lock when the system sleeps"; and "Longest
  unlocked time, hours (0: no limit)";
- "Seconds a request waits for an approval";
- "Minutes an approval code is valid";
- "Minutes between pulls of the GitHub vaults (0: off)";
- "Keep the last fetched vault files as an offline cache";
- "Days before a key expires that the reminders start";
- "Approval link address (VPN or LAN address:port; empty: no link)".

"Save" applies them; some apply at the next unlock, and the message says
which. **"Command-line approvals"** lets `tsm allow` and `tsm approve-code`
on this machine pre-approve clients and make approval tokens without a
person; it is off by default and switched only here.

**This app** (kept in its preferences): "Keep the window out of screenshots
and screen sharing" (Linux cannot), "Start the app at login, in the tray"
(macOS: a login item; Windows: the `Run` key of your user; Linux: an
autostart entry in `~/.config/autostart`),
and "Stop the service" (programs then get no secrets until it is started and
unlocked again).

**Integrations** (this user's tool configuration on this machine): "ssh
uses the ssh-agent" (`IdentityAgent` in `~/.ssh/config`; "For the hosts"
takes ssh `Host` patterns, "Apply" writes them) and "git asks Tom Secrets
Manager for credentials" (`credential.helper tsm` in `~/.gitconfig`, and
`git-credential-tsm` beside `tsm`). Each is a block between
`# >>> tom secrets >>>` and `# <<< tom secrets <<<`; switching off removes
it, and nothing outside it changes. What is not right is said, for example
that the folder of `tsm` is not on `PATH`, so git does not find the helper.
At every start the app checks that the blocks still name this machine's
agent and helper, rewrites one that does not, and tells you.

Under **Browsers** each browser found for your user (Chrome, Chromium, Edge,
Brave, Firefox) has a switch: on, the app writes the browser's
native-messaging manifest `net.tom.secrets.json` (on Windows also its
registry value), which lets the Tom Secrets Manager browser extension start
the browser host `tsm-browser-host` that ships beside the service; off
removes it. A Linux browser installed as a Flatpak or a Snap is named but
not offered: its sandbox cannot start the host. At every start the app checks
that each manifest still names its own host (after an update or a move it
rewrites it and tells you). The extension's "Open in Tom Secrets Manager"
brings the app to the front at the entry.

**Shared by every device**: the configuration kept in the primary vault
(`tsm.config`): the dimensions in priority order and the files per
environment, edited as YAML and saved with "Save in the primary vault". For
example (demo values):

```yaml
dimensions:
  - name: host
  - name: env
    default: dev
stores:
  prod:
    - name: prod
      github: {repository: owner/vault, path: prod.kdbx}
```

## Status

**Status** shows the service ("Running since", "Version and protocol",
"Lock mode", "Admins attached"), each vault with its state, source, last
fetch and changes not yet on GitHub, and the hardening the service
achieved. "Fetch every vault now" pulls the GitHub vaults at once.

## Troubleshooting

### A vault says "offline copy"

GitHub is not reachable, or the GitHub token expired. The vault is served
from its last fetched copy and opens read-only; a change cannot be written
("The vault is served from its offline copy"). A copy older than a week is
flagged as possibly out of date. When the network is back, "Fetch every
vault now" on the Status screen; when the token expired, renew it on
[Keys](#keys).

### "GitHub refused the token" or "The token does not see the repository"

The token is mistyped, expired or revoked, or it was made without the
repository. Make a new fine-grained token with the repository selected under
Repository access and Contents: Read and write, and renew it on
[Keys](#keys). "The token may read the repository but not write to it"
means it lacks Contents: Read and write.

### "The vault changed meanwhile"

Another device saved first; the vault was read again. Make the change once
more.

### "The branch on GitHub was rewritten"

Someone replaced the history of the vault's branch on GitHub (a force push)
other than by the app's own history cut. The app refuses to save and does
not read the vault again until you choose: open the vault's menu "The
rewritten branch…" (or "Choose…" on the Status screen):

- **"Take the file on GitHub"**: follow the rewritten branch as it is; your
  refused change is dropped (make it again if needed);
- **"Merge this copy over it"**: merge this machine's copy, your change
  included, into the file on GitHub and commit it on top; fields changed on
  both sides wait under [Conflicts](#conflicts);
- **"Later"**: decide another time.

### "Wrong master password or key file"

Check the password and that the key file is the vault's current one (after a
rotation, the new one).

### "The service accepts no admin from this app here"

The app must be installed beside the service it talks to, or named in the
service's bootstrap. Start the app from the installed folder rather than a
copy elsewhere.

### A program waits and no prompt appears

Look under Clients › "Approvals". On a machine without the app, the program
shows an approval code: answer it from your desktop under Clients ›
"Approval code".

### Pairing does not connect

Allow the app through the firewall when asked; on a VPN, type the address
the giving machine shows; on Linux the network discovery needs
`avahi-daemon` running. The code works once and the window closes after
five minutes: open a new one.
