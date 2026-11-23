# The relay server's container image (part-relay, DP-67): the bundle
# `dart build cli` writes (the AOT executable and tom_pqc's native library)
# on `scratch`, with the Dart image's /runtime (the C library both need).
# Build it from this package's folder:
#
#   docker build -t tom_secrets_relay .
#
# The configuration is mounted at /config/relay.yaml (relay.example.yaml
# lists every setting); the storage directory (`relay.storage`) belongs on
# a volume at /data. Plain HTTP: a reverse proxy terminates TLS. The health
# check is the executable's own `health` mode (no curl on scratch).

FROM dart:3.13 AS build
# tom_pqc's build hook compiles its vendored C code.
RUN apt-get update \
 && apt-get install -y --no-install-recommends clang \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get --enforce-lockfile
COPY . .
RUN dart build cli -t bin/tom_secrets_relay.dart -o /out

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out/bundle /app
USER 65532:65532
WORKDIR /data
EXPOSE 47910
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD ["/app/bin/tom_secrets_relay", "health", "config=/config/relay.yaml"]
ENTRYPOINT ["/app/bin/tom_secrets_relay"]
CMD ["config=/config/relay.yaml"]
