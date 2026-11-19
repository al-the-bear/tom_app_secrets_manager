// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import AuthenticationServices
import SwiftUI

/// The macOS AutoFill credential provider (part-os-integration, DP-50,
/// DP-51). It reads the snapshot the desktop app writes into the App Group
/// container after Touch ID or the login password, lists the logins that
/// match the field's service identifiers by the browser's rules, offers a
/// search over all of them, and completes the request with the login
/// picked. It writes nothing and cannot save; what it read is gone when it
/// closes. A QuickType suggestion (the app's credential identities: site
/// and user name, no password) opens it for Touch ID, since the password
/// cannot be given without it.
final class CredentialProviderViewController: ASCredentialProviderViewController {
  private let model = TomSecretsAutofillModel()

  override func loadView() {
    view = NSHostingView(
      rootView: TomSecretsAutofillListView(
        model: model,
        pick: { [weak self] in self?.complete(with: $0) },
        cancel: { [weak self] in self?.cancel() }))
  }

  // MARK: The list of logins.

  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    model.codes = false
    load(for: serviceIdentifiers)
  }

  /// One-time codes (macOS 15): the TOTP of the snapshot's logins.
  @available(macOS 15.0, *)
  override func prepareOneTimeCodeCredentialList(
    for serviceIdentifiers: [ASCredentialServiceIdentifier]
  ) {
    model.codes = true
    load(for: serviceIdentifiers)
  }

  // MARK: A QuickType suggestion.

  /// The password needs Touch ID: never given without the interface.
  override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
    extensionContext.cancelRequest(
      withError: NSError(
        domain: ASExtensionErrorDomain,
        code: ASExtensionError.userInteractionRequired.rawValue))
  }

  override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
    model.codes = false
    let id = credentialIdentity.recordIdentifier
    read { [weak self] snapshot in
      guard let self else { return }
      if let entry = snapshot.entries.first(where: { $0.id == id }) {
        self.complete(with: entry)
      } else {
        // The login changed or went since the identity was registered.
        self.model.matches = tomSecretsMatchingEntries(
          snapshot.entries, for: [Self.identifier(credentialIdentity.serviceIdentifier)])
      }
    }
  }

  override func prepareInterfaceForExtensionConfiguration() {
    model.message =
      "Tom Secrets Manager fills logins from the vaults on this Mac. Open the app and unlock it once; it prepares them for AutoFill."
  }

  // MARK: Reading and completing.

  private func load(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    read { [weak self] snapshot in
      self?.model.matches = tomSecretsMatchingEntries(
        snapshot.entries, for: serviceIdentifiers.map(Self.identifier))
    }
  }

  private func read(then: @escaping (TomSecretsAutofillSnapshot) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result {
        try TomSecretsSnapshotReader.read(reason: "fill a login from Tom Secrets Manager")
      }
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let snapshot):
          self.model.snapshot = snapshot
          then(snapshot)
        case .failure(let error):
          if case TomSecretsReaderError.cancelled = error {
            self.cancel()
          } else {
            self.model.message =
              (error as? TomSecretsReaderError)?.message ?? TomSecretsReaderError.unreadable.message
          }
        }
      }
    }
  }

  private func complete(with entry: TomSecretsAutofillEntry) {
    if model.codes {
      if #available(macOS 15.0, *), let code = entry.totp?.code() {
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
      } else {
        cancel()
      }
      return
    }
    extensionContext.completeRequest(
      withSelectedCredential: ASPasswordCredential(user: entry.userName, password: entry.password))
  }

  private func cancel() {
    extensionContext.cancelRequest(
      withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
  }

  static func identifier(_ s: ASCredentialServiceIdentifier) -> TomSecretsServiceIdentifier {
    s.type == .URL ? .url(s.identifier) : .domain(s.identifier)
  }
}
