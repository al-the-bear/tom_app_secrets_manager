# Changelog

## 0.3.1

- An instance token written as a `secret:` reference in `relay.tokens` is
  refused at start: the relay resolves no reference, and the reference
  itself would have become the token. `relay.example.yaml` no longer
  suggests one.
- The operator's guide (`doc/user_guide.md`): building, configuring,
  tokens, address lists, limits and blocks, a reverse proxy (Apache),
  health checks, storage, logs, upgrading; its `curl` transcripts are
  written by `test/guide_transcripts_test.dart`.

## 0.3.0

- The per-address denial-of-service defaults are 10 requests a second, 120
  a minute and 2,000 a day (were 2, 100 and 500, which a single mailbox
  read of the client blocked for a day); `tom_secrets_core` 0.2.24's client
  paces itself at about half of them. A test runs a device's normal use
  (shares to six members, a mailbox read, a pairing, a link) against the
  default limits, paced and unpaced.

## 0.2.0

- The container image (`Dockerfile`): the AOT bundle on `scratch` with the
  Dart image's `/runtime`, uid 65532, `/config/relay.yaml`, `/data`, its
  health check the new `health` mode (`tom_secrets_relay health`, which asks
  the running relay's `/health` and exits 0 or 1;
  `tomSecretsRelayHealthCheck`, `tomSecretsRelayHealthUrl`).
- The `Authorization` header under `/v1/` is claimed as the relay's own
  credential (`TomEndpointCredentials`): an instance token or a proof is no
  longer read as a framework JWT, which logged a warning per request.

## 0.1.0

- The relay server (part-relay, phase C) on `tom_core_server`: the pairing
  rendezvous (`POST /v1/pair`, the WebSocket `/v1/pair/<nameplate>`), the
  approval link (the WebSocket `/v1/link/<link-id>`), the mailbox
  (`PUT`/`GET`/`DELETE /v1/mailbox/<recipient>/<item-id>`, the listing, the
  recipient's proof), `/health` and `/ready`; token mode by default, the
  address filters, the denial-of-service blocks kept across restarts, the
  limits, the expiry job.
