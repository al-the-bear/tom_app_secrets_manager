// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause
//
// The Windows passkey plugin's portable core (part-os-integration, DP-120):
// what a decoded CTAP2 request becomes as the service's passkey requests
// (protocol.md 5.8), and what the service's answers become for Windows. The
// plugin never holds a passkey's key: the service lists passkeys by name,
// signs, and makes new ones once the user confirms them in the app.
#pragma once

#include <stdexcept>
#include <string>
#include <vector>

namespace tsm_plugin {

using Bytes = std::vector<unsigned char>;

/// base64url without padding.
std::string base64url(const Bytes &bytes);

/// The bytes of base64url (or base64) text; throws std::invalid_argument.
Bytes fromBase64url(const std::string &text);

/// Why a request failed, as the plugin answers Windows.
enum class Failure {
  notAllowed,   // no passkey of the site, or the service refused it
  excluded,     // the site holds this account's passkey already
  notSupported, // no algorithm the site offers is made
  cancelled,    // the user said no in the app, or nobody answered
  locked,       // the service is locked
  notRunning,   // no service answers
  other,
};

/// A refused or failed request.
struct PluginError : std::runtime_error {
  PluginError(Failure f, const std::string &message)
      : std::runtime_error(message), failure(f) {}
  Failure failure;
};

/// A passkey of a site, as `passkeys` answers it.
struct Candidate {
  std::string entryId;
  std::string title;
  std::string userName;
  std::string credentialId; // base64url
};

/// A sign-in signed by the service (`passkeyAssertion`), base64url.
struct Signature {
  std::string credentialId;
  std::string authenticatorData;
  std::string signature;
  std::string userHandle; // empty when the passkey has none
};

/// A new passkey's request (`passkeyCreate`).
struct CreateRequest {
  std::string url;
  std::string rpId;
  Bytes userId;
  std::string userName;
  std::string displayName;
  std::vector<int> algorithms;
  std::vector<std::string> exclude; // base64url
};

/// A passkey just made and kept (`passkeyCreated`), base64url.
struct Created {
  std::string credentialId;
  std::string authenticatorData;
  std::string attestationObject;
  std::string publicKey;
  int algorithm = 0;
};

/// The service, as the plugin asks it (the C client; a fake in tests).
class PasskeyService {
public:
  virtual ~PasskeyService() = default;
  virtual std::vector<Candidate> passkeys(const std::string &url,
                                          const std::string &rpId,
                                          const std::vector<std::string> &allow,
                                          bool wait) = 0;
  virtual Signature sign(const std::string &url, const std::string &rpId,
                         const std::string &entryId, const Bytes &clientDataHash) = 0;
  virtual Created create(const CreateRequest &request) = 0;
};

/// A decoded `authenticatorMakeCredential`.
struct MakeCredentialInput {
  std::string rpId;
  Bytes clientDataHash;
  Bytes userId;
  std::string userName;
  std::string displayName;
  std::vector<int> algorithms;
  std::vector<Bytes> exclude;
};

/// What the plugin answers it: the authenticator data with the attested
/// credential (the `none` attestation), and the credential id.
struct MakeCredentialOutput {
  Bytes authenticatorData;
  Bytes credentialId;
};

/// A decoded `authenticatorGetAssertion`.
struct GetAssertionInput {
  std::string rpId;
  Bytes clientDataHash;
  std::vector<Bytes> allow; // the credential the user picked in Windows
};

/// What the plugin answers it.
struct GetAssertionOutput {
  Bytes credentialId;
  Bytes authenticatorData;
  Bytes signature;
  Bytes userHandle;
};

/// The page the service is told: Windows checked the caller's origin
/// against the relying party and signed the request, so the plugin names
/// the relying party's own address.
std::string pageUrlOf(const std::string &rpId);

/// A new passkey for [in], made and kept by the service once the user
/// confirms it in the app.
MakeCredentialOutput makeCredential(PasskeyService &service, const MakeCredentialInput &in);

/// A sign-in with the passkey [in] allows (the one picked in Windows), or
/// the site's only one.
GetAssertionOutput getAssertion(PasskeyService &service, const GetAssertionInput &in);

/// Whether the service answers unlocked (`passkeys` of a reserved name,
/// without waiting).
bool unlocked(PasskeyService &service);

/// A passkey's names for Windows' list (never a key).
struct CredentialDetails {
  Bytes credentialId;
  std::string rpId;
  std::string rpName;
  Bytes userId;
  std::string userName;
  std::string displayName;
};

/// The lines `--sync-credentials` reads: per passkey six tab-separated
/// base64url fields (credential id, relying party, its name, user id, user
/// name, display name; the texts as UTF-8). Blank lines are skipped; a
/// malformed line throws std::invalid_argument.
std::vector<CredentialDetails> parseCredentialLines(const std::string &text);

/// The plugin's CTAP2 `authenticatorGetInfo`, CBOR: FIDO_2_0 and 2.1, the
/// all-zero AAGUID the service's authenticator data carry, resident keys,
/// user presence and verification, the internal transport, ES256 and
/// Ed25519.
Bytes authenticatorInfo();

/// The plugin's class id, as text.
extern const char *const pluginClassId;

} // namespace tsm_plugin
