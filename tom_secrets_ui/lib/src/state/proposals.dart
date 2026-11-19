// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Proposed logins (part-app, Proposals; BP-28, DP-43, DP-52): what the
/// browser extension saw submitted on a page, and what git's credential
/// helper saw work, arrive as the service's `proposal` event (protocol.md
/// 5.5). The app keeps them in memory only, until the user saves one as a
/// new login, updates an existing login with it, or drops it; the lock
/// forgets them.
library;

import 'package:flutter/foundation.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

/// One proposed login.
@immutable
final class TomSecretsProposal {
  /// Proposal [id] of [url] with [userName] and [password], titled [title].
  const TomSecretsProposal({
    required this.id,
    required this.url,
    required this.userName,
    required this.password,
    required this.title,
    required this.received,
  });

  /// The proposal of the `proposal` [event] numbered [id], or null when it
  /// lacks the url, the user name or the password.
  static TomSecretsProposal? fromEvent(
    Map<String, Object?> event,
    int id, {
    DateTime? now,
  }) {
    final url = event['url'];
    final userName = event['userName'];
    final password = event['password'];
    if (url is! String || userName is! String || password is! String) {
      return null;
    }
    final title = event['title'];
    return TomSecretsProposal(
      id: id,
      url: url,
      userName: userName,
      password: password,
      title: title is String && title.trim().isNotEmpty ? title.trim() : null,
      received: now ?? DateTime.now(),
    );
  }

  /// Its number in this app run.
  final int id;

  /// The page (the browser) or `https://<host>/` (git).
  final String url;

  /// The user name.
  final String userName;

  /// The password; held in memory only.
  final String password;

  /// The title the page or the tool gave, or null.
  final String? title;

  /// When it arrived.
  final DateTime received;

  /// The site: the address's host, or the address as written.
  String get site {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }

  /// The title a new login gets: [title], else the site.
  String get suggestedTitle => title ?? site;

  /// The URL a new login stores: the page's origin (scheme and host, no
  /// path or query, which may carry tokens).
  String get entryUrl {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return url;
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
    ).toString();
  }
}

/// A login the proposal may update: an entry of a writable vault whose URLs
/// match the proposal's page and whose user name is the proposal's.
typedef TomSecretsProposalMatch = ({
  String store,
  KdbxUuid uuid,
  String title,
  String matchedUrl,
  bool samePassword,
});

/// The logins of [entries] that [proposal] would update (same user name,
/// URL matching by 5.7), the exact host first.
List<TomSecretsProposalMatch> tomSecretsProposalMatches(
  TomSecretsProposal proposal,
  Iterable<TomSecretsIndexedEntry> entries,
) => [
  for (final m in tomSecretsMatchLogins(entries, proposal.url))
    if (m.userName == proposal.userName)
      (
        store: m.entry.store,
        uuid: m.entry.entry.uuid,
        title: m.title,
        matchedUrl: m.matchedUrl,
        samePassword:
            m.entry.entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ==
            proposal.password,
      ),
];

/// Writes [proposal] into [entry] as a new login: title, user name,
/// password (protected) and the page's origin as its URL.
void tomSecretsFillFromProposal(
  KdbxEntry entry,
  TomSecretsProposal proposal, {
  String? title,
}) {
  entry
    ..label = (title == null || title.trim().isEmpty)
        ? proposal.suggestedTitle
        : title.trim()
    ..setString(KdbxKeyCommon.USER_NAME, PlainValue(proposal.userName))
    ..setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString(proposal.password),
    )
    ..setString(KdbxKeyCommon.URL, PlainValue(proposal.entryUrl));
}

/// Updates [entry] with [proposal]'s password; the entry as it was goes to
/// its history (the store's first change of an entry since the file was
/// read pushes it), so Restore in the editor brings it back.
void tomSecretsApplyProposal(KdbxEntry entry, TomSecretsProposal proposal) =>
    entry.setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString(proposal.password),
    );
