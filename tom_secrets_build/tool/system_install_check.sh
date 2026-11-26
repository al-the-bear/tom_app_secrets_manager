#!/usr/bin/env bash
# Copyright (c) 2026 Peter Nicolai Alexis Kyaw
# SPDX-License-Identifier: BSD-3-Clause
#
# The system install of the service (tsm install --system, tsm_d11), checked
# as root in a throwaway Linux container (ci.sh :system starts it): the
# service and tsm built from the working tree, installed, used by three demo
# users, uninstalled. Demo data only; nothing leaves the container.
#
# Mounted: /mnt/manager (tom_secrets_manager), /mnt/clients
# (tom_secrets_clients). Prints PASS / FAIL lines; exits 1 on a FAIL.
set -u
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
expect() { # expect <what> <command...>: the command succeeds
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}
refuse() { # refuse <what> <command...>: the command fails
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$what"; else ok "$what"; fi
}
as() { local who="$1"; shift; su - "$who" -c "$*"; }
password='primary-demo-pw'

echo "== tools"
apt-get update -qq >/dev/null && apt-get install -y -qq clang gcc libc6-dev procps \
  >/dev/null || { echo "FAIL: apt-get"; exit 1; }

echo "== the working tree"
mkdir -p /src/tom_ai/secrets_manager /src/tom_ai/secrets_clients/clients/dart
tar -C /mnt/manager --exclude=.dart_tool --exclude=build --exclude=testlog \
  -cf - tom_secrets_service tom_secrets_core tom_secrets_age \
  | tar -C /src/tom_ai/secrets_manager -xf -
tar -C /mnt/clients/clients/dart --exclude=.dart_tool --exclude=build \
  --exclude=testlog -cf - tom_secrets_client tsm \
  | tar -C /src/tom_ai/secrets_clients/clients/dart -xf -

echo "== build"
service=/src/tom_ai/secrets_manager/tom_secrets_service
tsmsrc=/src/tom_ai/secrets_clients/clients/dart/tsm
(cd "$service" && dart pub get >/dev/null && dart build cli \
  -t bin/tom_secrets_service.dart -o /build >/dev/null) \
  || { echo "FAIL: build the service"; exit 1; }
(cd "$tsmsrc" && dart pub get >/dev/null && dart compile exe bin/tsm.dart \
  -o /build/bundle/bin/tsm >/dev/null) || { echo "FAIL: build tsm"; exit 1; }
chmod -R a+rX /build
release=/build/bundle/bin

cat >/tmp/evil.c <<'EOF'
#include <stdio.h>
#include <unistd.h>
__attribute__((constructor)) static void mark(void) {
  char p[64];
  snprintf(p, sizeof p, "/tmp/evil-%d", (int)getpid());
  FILE *f = fopen(p, "w");
  if (f) fclose(f);
}
EOF
gcc -shared -fPIC -o /tmp/evil.so /tmp/evil.c && chmod 755 /tmp/evil.so

echo "== demo users"
for u in demo other old; do
  useradd -m -s /bin/bash "$u"
  (cd "$service" && dart run tool/demo_installation.dart \
    "/home/$u/.local/share/tom-secrets-manager" "/home/$u/vaults" >/dev/null)
  chown -R "$u:$u" "/home/$u"
done
uid() { id -u "$1"; }
pidof_service() { sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "/tmp/tsm-$(uid "$1")/service.json"; }
pubkey() { sed -n 's/.*"publicKey":"\([^"]*\)".*/\1/p' "$1"; }

echo "== before the install: old's service keeps its key in its data directory"
as old "printf '%s\n' $password | TSM_SERVICE=$release/tom_secrets_service \
  $release/tsm --password-stdin start --unlock" >/dev/null
oldfile=/home/old/.local/share/tom-secrets-manager/service-identity.json
expect "old's key in its data directory" test -f "$oldfile"
oldkey=$(pubkey "$oldfile")
as old "printf '%s\n' $password | $release/tsm --password-stdin stop" >/dev/null

echo "== install"
out=$("$release/tsm" install --system 2>&1) || { echo "$out"; bad "install"; }
expect "installed" test -x /opt/tom-secrets-manager/bin/tom_secrets_service
expect "the service is root's, set-group-ID to tsm-identity" \
  test "$(stat -c '%U:%G %a' /opt/tom-secrets-manager/bin/tom_secrets_service)" = 'root:tsm-identity 2755'
expect "the identity directory is the group's alone" \
  test "$(stat -c '%U:%G %a' /var/lib/tom-secrets-manager/identity)" = 'root:tsm-identity 2770'
expect "the record is root's, readable" \
  test "$(stat -c '%U %a' /etc/tom-secrets-manager/system.json)" = 'root 644'
expect "tsm is linked for every user" test -L /usr/local/bin/tsm

echo "== demo: start and unlock the installed service"
first=$(as demo "printf '%s\n' $password | tsm --password-stdin start --unlock" 2>&1)
echo "$first" | grep -q '^unlocked' && ok "started and unlocked" || { echo "$first"; bad "started and unlocked"; }
words=$(echo "$first" | sed -n 's/^identity //p' | head -1)
expect "the identity words are shown" test -n "$words"
status=$(as demo "printf '%s\n' $password | tsm --password-stdin status --json" 2>&1)
echo "$status" | grep -q '"kept": "system"' && ok "status: the key is kept by the system install" \
  || { echo "$status"; bad "status: kept system"; }
keyfile=/var/lib/tom-secrets-manager/identity/$(uid demo).json
expect "the key file is demo's, the group's, 0640" \
  test "$(stat -c '%U:%G %a' "$keyfile")" = 'demo:tsm-identity 640'
refuse "demo cannot list the identity directory" as demo "ls /var/lib/tom-secrets-manager/identity"
refuse "demo cannot read its own key file" as demo "cat $keyfile"
refuse "another user cannot read it" as other "cat $keyfile"
expect "no key in demo's data directory" \
  test ! -e /home/demo/.local/share/tom-secrets-manager/service-identity.json

pid=$(pidof_service demo)
expect "the service runs as demo" test "$(stat -c '%U' /proc/"$pid")" = demo
gids=$(awk '/^Gid:/ {print $2, $3, $4, $5}' /proc/"$pid"/status)
g=$(id -g demo)
expect "the group is dropped (real, effective, saved, fs: $gids)" test "$gids" = "$g $g $g $g"
refuse "demo cannot read the service's environment" as demo "cat /proc/$pid/environ"
refuse "demo cannot read the service's memory" as demo "head -c 1 /proc/$pid/mem"
refuse "demo cannot attach to the service" as demo "cat /proc/$pid/maps"

echo "== a restart: the same identity"
as demo "printf '%s\n' $password | tsm --password-stdin stop" >/dev/null
again=$(as demo "printf '%s\n' $password | LD_PRELOAD=/tmp/evil.so tsm --password-stdin start" 2>&1)
expect "the same words after a restart" test "$(echo "$again" | sed -n 's/^identity //p' | head -1)" = "$words"
pid=$(pidof_service demo)
expect "LD_PRELOAD works for an ordinary program (tsm)" sh -c 'ls /tmp/evil-* >/dev/null'
expect "the service ignored LD_PRELOAD" test ! -e "/tmp/evil-$pid"

echo "== the environment does not move it"
as demo "printf '%s\n' $password | tsm --password-stdin stop" >/dev/null
as demo "TSM_RUNTIME_DIR=/tmp/elsewhere tsm start" >/dev/null 2>&1
sleep 2
expect "its runtime directory is the account's" test -f "/tmp/tsm-$(uid demo)/service.json"
expect "not the one the variable named" test ! -e /tmp/elsewhere/service.json
as demo "printf '%s\n' $password | tsm --password-stdin stop" >/dev/null

echo "== old: the key it had signs the installed one"
as old "printf '%s\n' $password | tsm --password-stdin start --unlock" >/dev/null
oldsystem=/var/lib/tom-secrets-manager/identity/$(uid old).json
expect "old's key moved into the identity directory" test -f "$oldsystem"
expect "its data-directory key is gone" test ! -e "$oldfile"
expect "the previous key signed the new one" grep -q "\"from\":\"$oldkey\"" "$oldsystem"
as old "printf '%s\n' $password | tsm --password-stdin stop" >/dev/null

echo "== uninstall"
"$release/tsm" uninstall --system >/dev/null 2>&1 || bad "uninstall"
expect "the programs are gone" test ! -e /opt/tom-secrets-manager
expect "the link is gone" test ! -e /usr/local/bin/tsm
expect "the record is gone" test ! -e /etc/tom-secrets-manager/system.json
expect "the identity keys stay" test -f "$keyfile"
"$release/tsm" uninstall --system --purge >/dev/null 2>&1 || bad "purge"
expect "--purge removes the keys" test ! -e /var/lib/tom-secrets-manager
refuse "--purge removes the group" getent group tsm-identity

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
