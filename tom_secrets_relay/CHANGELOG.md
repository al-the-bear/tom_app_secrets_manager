# Changelog

## 0.2.0

- The container image (`Dockerfile`): the AOT bundle on `scratch` with the
  Dart image's `/runtime`, uid 65532, `/config/relay.yaml`, `/data`, its
  health check the new `health` mode (`tom_secrets_relay health`, which asks
  the running relay's `/health` and exits 0 or 1;
  `tomSecretsRelayHealthCheck`, `tomSecretsRelayHealthUrl`).

## 0.1.0

- The relay server (part-relay, phase C) on `tom_core_server`: the pairing
  rendezvous (`POST /v1/pair`, the WebSocket `/v1/pair/<nameplate>`), the
  approval link (the WebSocket `/v1/link/<link-id>`), the mailbox
  (`PUT`/`GET`/`DELETE /v1/mailbox/<recipient>/<item-id>`, the listing, the
  recipient's proof), `/health` and `/ready`; token mode by default, the
  address filters, the denial-of-service blocks kept across restarts, the
  limits, the expiry job.
