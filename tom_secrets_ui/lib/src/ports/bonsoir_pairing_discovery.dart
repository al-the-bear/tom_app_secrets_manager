// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The pairing discovery port over `bonsoir` (MIT; macOS and iOS through
/// Network.framework's Bonjour, Android through its NsdManager, Windows
/// through its DNS-SD API, Linux through Avahi over D-Bus), shared by the
/// desktop and the mobile app: an open pairing window advertised as
/// `_tsm-pair._tcp` with its code's number and addresses in the TXT record,
/// and the windows on the LAN browsed for a few seconds.
library;

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'pairing_discovery.dart';

/// The pairing discovery of the desktop and the mobile app.
final class TomSecretsBonsoirPairingDiscovery
    implements TomSecretsPairingDiscovery {
  /// The discovery.
  const TomSecretsBonsoirPairingDiscovery();

  @override
  Future<TomSecretsPairingAdvertising> advertise(
    TomSecretsPairingAdvert advert,
  ) async {
    final broadcast = BonsoirBroadcast(
      printLogs: false,
      service: BonsoirService(
        name: advert.device,
        type: tomSecretsPairingServiceType,
        port: advert.port,
        attributes: advert.txt,
      ),
    );
    await broadcast.initialize();
    await broadcast.start();
    return _Broadcasting(broadcast);
  }

  @override
  Future<List<TomSecretsPairingAdvert>> browse({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final discovery = BonsoirDiscovery(
      printLogs: false,
      type: tomSecretsPairingServiceType,
    );
    await discovery.initialize();
    final seen = <String, TomSecretsPairingAdvert>{};
    final subscription = discovery.eventStream!.listen((event) {
      final service = event.service;
      if (service == null) return;
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          unawaited(
            Future.sync(
              () => discovery.serviceResolver.resolveService(service),
            ).catchError((Object _) {}),
          );
        case BonsoirDiscoveryServiceResolvedEvent() ||
            BonsoirDiscoveryServiceUpdatedEvent():
          final advert = TomSecretsPairingAdvert.fromTxt(
            device: service.name,
            port: service.port,
            txt: service.attributes,
            resolvedAddresses: service.hostAddresses,
          );
          if (advert != null) seen[service.name] = advert;
        case BonsoirDiscoveryServiceLostEvent():
          seen.remove(service.name);
        default:
          break;
      }
    });
    try {
      await discovery.start();
      await Future<void>.delayed(timeout);
    } finally {
      await subscription.cancel();
      await discovery.stop();
    }
    return seen.values.toList();
  }
}

final class _Broadcasting implements TomSecretsPairingAdvertising {
  _Broadcasting(this._broadcast);

  final BonsoirBroadcast _broadcast;

  @override
  Future<void> stop() => _broadcast.stop();
}
