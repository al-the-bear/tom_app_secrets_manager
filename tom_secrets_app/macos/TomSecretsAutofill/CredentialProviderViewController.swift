// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import AuthenticationServices
import SwiftUI

/// The macOS AutoFill credential provider (part-os-integration, DP-50,
/// DP-51). It reads the snapshot the desktop app writes into the App Group
/// container after Touch ID or the login password, lists the logins that
/// match the field's service identifiers by the browser's rules, offers a
/// search over all of them, and completes the request with the login
/// picked. A QuickType suggestion (the app's credential identities: site
/// and user name, no password) opens it for Touch ID, since the password
/// cannot be given without it.
///
/// **[C]** Passkeys (macOS 14): a sign-in is signed with a passkey of the
/// snapshot (or one made here that the app has not saved yet), after Touch
/// ID, as an authenticator whose credentials are synced (backup eligible,
/// backed up). A new passkey is made here with the site's first algorithm
/// this provider has (ES256, Ed25519) and added to the pending file, the
/// one file the extension writes; the app saves it into a vault at its next
/// sync. Its private key never leaves the Mac's vaults and this file.
final class CredentialProviderViewController: ASCredentialProviderViewController {
  private let model = TomSecretsAutofillModel()

  override func loadView() {
    view = NSHostingView(
      rootView: TomSecretsAutofillListView(
        model: model,
        pick: { [weak self] in self?.complete(with: $0) },
        pickPasskey: { [weak self] in self?.sign(with: $0) },
        register: { [weak self] in self?.registerPasskey() },
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

  /// A page that asks for a passkey (macOS 14): the site's passkeys.
  @available(macOS 14.0, *)
  override func prepareCredentialList(
    for serviceIdentifiers: [ASCredentialServiceIdentifier],
    requestParameters: ASPasskeyCredentialRequestParameters
  ) {
    model.codes = false
    model.passkeyRequest = .assertion(
      rpId: requestParameters.relyingPartyIdentifier,
      clientDataHash: requestParameters.clientDataHash,
      allowed: requestParameters.allowedCredentials)
    read { [weak self] snapshot in
      self?.model.passkeys = tomSecretsMatchingPasskeys(
        snapshot.passkeys, pending: TomSecretsSnapshotReader.pendingPasskeys(),
        rpId: requestParameters.relyingPartyIdentifier,
        allowed: requestParameters.allowedCredentials)
    }
  }

  // MARK: A QuickType suggestion.

  /// The password needs Touch ID: never given without the interface.
  override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
    userInteractionRequired()
  }

  /// A password or a passkey needs Touch ID: never given without the
  /// interface (macOS 14).
  @available(macOS 14.0, *)
  override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
    userInteractionRequired()
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

  /// A QuickType suggestion of a password or a passkey (macOS 14).
  @available(macOS 14.0, *)
  override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
    if let password = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
      prepareInterfaceToProvideCredential(for: password)
      return
    }
    guard let request = credentialRequest as? ASPasskeyCredentialRequest,
      let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
    else { return cancel() }
    model.codes = false
    model.passkeyRequest = .assertion(
      rpId: identity.relyingPartyIdentifier, clientDataHash: request.clientDataHash,
      allowed: [identity.credentialID])
    read { [weak self] snapshot in
      guard let self else { return }
      let passkeys = tomSecretsMatchingPasskeys(
        snapshot.passkeys, pending: TomSecretsSnapshotReader.pendingPasskeys(),
        rpId: identity.relyingPartyIdentifier, allowed: [identity.credentialID])
      if let passkey = passkeys.first {
        self.sign(with: passkey)
      } else {
        // The passkey went since the identity was registered.
        self.model.passkeys = []
      }
    }
  }

  /// A site that makes a passkey (macOS 14): asked first, then made here.
  @available(macOS 14.0, *)
  override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
    guard let request = registrationRequest as? ASPasskeyCredentialRequest,
      let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
    else { return cancel() }
    let algorithms = request.supportedAlgorithms.map { $0.rawValue }
    guard algorithms.contains(where: { $0 == TomSecretsWebAuthn.es256 || $0 == TomSecretsWebAuthn.edDsa })
    else {
      model.message = "This site asks for a kind of passkey Tom Secrets Manager does not make."
      return
    }
    model.codes = false
    model.passkeyRequest = .registration(
      rpId: identity.relyingPartyIdentifier, userName: identity.userName,
      userHandle: identity.userHandle, clientDataHash: request.clientDataHash,
      algorithms: algorithms)
  }

  override func prepareInterfaceForExtensionConfiguration() {
    model.message =
      "Tom Secrets Manager fills logins and passkeys from the vaults on this Mac. Open the app and unlock it once; it prepares them for AutoFill."
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
        try TomSecretsSnapshotReader.read(reason: "use a login or passkey from Tom Secrets Manager")
      }
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let snapshot):
          self.model.snapshot = snapshot
          then(snapshot)
        case .failure(let error):
          self.show(error)
        }
      }
    }
  }

  private func show(_ error: Error) {
    if case TomSecretsReaderError.cancelled = error {
      cancel()
    } else {
      model.message =
        (error as? TomSecretsReaderError)?.message ?? TomSecretsReaderError.unreadable.message
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

  /// Signs the sign-in with [passkey] (the snapshot was read: Touch ID
  /// verified the user).
  private func sign(with passkey: TomSecretsAutofillPasskey) {
    guard #available(macOS 14.0, *),
      case .assertion(_, let clientDataHash, _) = model.passkeyRequest,
      let credentialId = passkey.credentialIdData
    else { return cancel() }
    do {
      let (authenticatorData, signature) = try TomSecretsWebAuthn.assertion(
        passkey, clientDataHash: clientDataHash)
      extensionContext.completeAssertionRequest(
        using: ASPasskeyAssertionCredential(
          userHandle: passkey.userHandleData ?? Data(), relyingParty: passkey.rpId,
          signature: signature, clientDataHash: clientDataHash,
          authenticatorData: authenticatorData, credentialID: credentialId))
    } catch {
      model.message = "This passkey cannot be used: open Tom Secrets Manager and check the entry."
    }
  }

  /// Makes the passkey the site asked for, after Touch ID (reading the
  /// snapshot verifies the user), and keeps it in the pending file.
  private func registerPasskey() {
    guard #available(macOS 14.0, *),
      case .registration(let rpId, let userName, let userHandle, let clientDataHash, let algorithms) =
        model.passkeyRequest
    else { return cancel() }
    read { [weak self] _ in
      guard let self else { return }
      do {
        let made = try TomSecretsWebAuthn.register(
          rpId: rpId, userHandle: userHandle, userName: userName.isEmpty ? nil : userName,
          algorithms: algorithms, id: "pending-\(UUID().uuidString.lowercased())")
        try TomSecretsSnapshotReader.addPending(made.passkey)
        self.extensionContext.completeRegistrationRequest(
          using: ASPasskeyRegistrationCredential(
            relyingParty: rpId, clientDataHash: clientDataHash,
            credentialID: made.credentialId, attestationObject: made.attestationObject))
      } catch {
        self.show(error is TomSecretsReaderError ? error : TomSecretsReaderError.unreadable)
      }
    }
  }

  private func userInteractionRequired() {
    extensionContext.cancelRequest(
      withError: NSError(
        domain: ASExtensionErrorDomain,
        code: ASExtensionError.userInteractionRequired.rawValue))
  }

  private func cancel() {
    extensionContext.cancelRequest(
      withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
  }

  static func identifier(_ s: ASCredentialServiceIdentifier) -> TomSecretsServiceIdentifier {
    s.type == .URL ? .url(s.identifier) : .domain(s.identifier)
  }
}
