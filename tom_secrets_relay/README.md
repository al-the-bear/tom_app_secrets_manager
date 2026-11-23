# Tom Secrets Relay

The Tom Secrets Manager's optional relay server: a `tom_core_server`
application that carries a pairing, an approval link or a share between
devices that do not reach each other on the network or over the VPN. It
sees only ciphertext: the pairing's and the link's own handshakes run inside
its channels, and a mailbox item is an `age` package. It imports no vault
format.

The apps reach it as the relay `tsm:<url>` (`tom_secrets_core`'s
`TomSecretsServerRelay`), listed in the desktop app's Sharing › Relays.

## What it serves

| Endpoint | Purpose |
| --- | --- |
| `POST /v1/pair` | allocates a nameplate (1–999, the pairing code's number) for 10 minutes: `{nameplate, expires}` |
| `GET /v1/pair/<nameplate>` (WebSocket) | the first two connections are joined, every binary frame of one sent to the other; a third is refused (409); the nameplate is released when a side leaves, or at its expiry |
| `GET /v1/link/<link-id>` (WebSocket) | the approval link: two connections joined, no expiry while both stay; a side alone waits up to 24 hours; a third is refused; the instance token in token mode |
| `PUT /v1/mailbox/<recipient>/<item-id>` | stores one `age` package; header `Tsm-Expires` (ISO 8601, at most 30 days ahead); the instance token in token mode; 409 when the id exists |
| `POST /v1/mailbox/<recipient>/challenge` | the recipient's proof: the body is the full recipient string (`age1pq1…`), which must hash to `<recipient>`; the answer is a token encrypted with `age` to it |
| `GET /v1/mailbox/<recipient>` | the items waiting: `{items: [{id, size, received, expires}]}`; needs the proof |
| `GET` / `DELETE /v1/mailbox/<recipient>/<item-id>` | one item, or deletes it; needs the proof |
| `GET /health`, `GET /ready` | the container's probes |

- `<recipient>` is the member's fingerprint: the base32 SHA-256 of the
  hybrid recipient string, 52 lower-case characters.
- The instance token and the proof travel as `Authorization: Bearer`. A
  proof is valid for 5 minutes.
- A refusal answers `{"error": "…"}` with its status; a 429 carries
  `Retry-After`. A WebSocket the relay ends gets a close code from 4000:
  4000 the other side left, 4400 a frame that is not binary, 4401 no
  token, 4404 no such nameplate, 4408 its time ran out, 4409 two sides are
  there, 4413 a frame or channel too large, 4429 too many links, 4503 the
  relay stops.
- Every other path, the framework's own services among them, answers 404.

## Protection

- **Who may send:** token mode (the default) takes mailbox puts and links
  only with an instance token, one per team or user; open mode takes them
  from anyone. Pairing needs no token in either mode; reading a mailbox
  always needs the proof. A relay in token mode without tokens says so at
  start-up.
- **Address filters:** a deny and an allow list of CIDR ranges, IPv4 and
  IPv6, checked first (403).
- **Denial of service:** an address making more than 2 requests in a
  second, 100 in a minute or 500 in a day is blocked: its connections are
  closed without an answer, 24 hours the first time, 48 the second, a week
  the third, each further block twice the one before. The block list is
  kept in the storage directory, so a restart lifts no block. `/health`
  and `/ready` are not counted.
- **Limits** (429 with `Retry-After`): 10 nameplates per address per hour,
  64 KB per frame and 1 MB per pairing channel; 10 open links per token,
  64 KB per frame; 30 puts per token (open mode: per address) per hour,
  1 MB per item, 200 items or 50 MB per recipient; 20 proof challenges per
  recipient per hour.
- **Expiry:** a job every 10 minutes deletes expired items and closes
  expired nameplates.
- **Logging:** method, route, status, size and duration; never a body; a
  recipient only as its first 8 characters.

## Running it

```text
dart run bin/tom_secrets_relay.dart config=relay.yaml
```

`relay.example.yaml` lists every setting with its default:
`tom_core_server`'s keys at the top (`port`, `host`, `logLevel`; use
`production` for info, warnings and errors), the relay's under `relay:`.
The environment and `key=value` arguments override the file. The relay
listens on plain HTTP (port 47910 by default) behind a reverse proxy that
terminates TLS and forwards the WebSockets; it trusts `X-Forwarded-For`
only from the addresses in `relay.trustedProxies` (the loopback by
default; in a container, the address the proxy's requests arrive from).
Nameplates and channels live in memory; the mailbox in the storage
directory, one file per item with a JSON index per recipient. The
framework's resource-key protection is on: only the relay's routes, all
public, are served.

`tom_secrets_relay health [config=<file>]` is a health check instead: it
asks the running relay's `/health` on the configured host and port (the
loopback when it listens on every address) and exits 0 when it answers 200,
else 1.

### In a container

The `Dockerfile` builds the image: the AOT bundle (`dart build cli`, the
executable and `tom_pqc`'s native library) on `scratch` with the Dart
image's `/runtime`, running as uid 65532, its health check the `health`
mode above.

```text
docker build -t tom_secrets_relay .
docker run -d --network host --read-only --cap-drop ALL \
  -v "$PWD/relay.yaml:/config/relay.yaml:ro" -v "$PWD/data:/data" \
  tom_secrets_relay
```

Mount the configuration at `/config/relay.yaml` and give the storage a
volume at `/data` (`relay.storage: /data`, owned by uid 65532). With host
networking, bind it to the loopback (`host: 127.0.0.1`) behind the proxy and
keep the default `trustedProxies`; with a published port, trust the address
the proxy's requests arrive from inside the container instead.
`tom_secrets_build/ci.sh :relay` builds the image too.

## Development

- `./reflection_generation.sh` regenerates
  `bin/tom_secrets_relay.reflection.dart` after a reflected type changes
  (`--check` verifies it).
- The tests (`testkit :test`) start the relay in the test's process:
  pairing, links, the mailbox with the proof, both modes, the filters and
  the blocks; with two real secrets services, the approval link through
  the relay, and a share put by a service's `relay.put` into members'
  mailboxes and read there with their keys.

## Licence

BSD 3-Clause ([LICENSE](LICENSE)). The relay links no copyleft package
(`tom_secrets_build`'s licence boundary checks it).
