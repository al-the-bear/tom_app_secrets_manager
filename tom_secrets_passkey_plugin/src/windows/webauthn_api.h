// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause
//
// The plugin functions of webauthn.dll, loaded with GetProcAddress (the
// SDK's webauthn.lib lacks them), and the conversions between Windows'
// decoded CTAP2 requests and encoded answers and the portable core.
#pragma once

#include <windows.h>
#include <webauthn.h>
#include <webauthnplugin.h>

#include <string>

#include "../core.h"

namespace tsm_plugin {

/// The webauthn.dll functions the plugin calls.
struct WebAuthnApi {
  decltype(&WebAuthNPluginAddAuthenticator) addAuthenticator = nullptr;
  decltype(&WebAuthNPluginFreeAddAuthenticatorResponse) freeAddResponse = nullptr;
  decltype(&WebAuthNPluginRemoveAuthenticator) removeAuthenticator = nullptr;
  decltype(&WebAuthNPluginGetAuthenticatorState) getState = nullptr;
  decltype(&WebAuthNPluginAuthenticatorAddCredentials) addCredentials = nullptr;
  decltype(&WebAuthNPluginAuthenticatorRemoveAllCredentials) removeAllCredentials = nullptr;
  decltype(&WebAuthNPluginGetOperationSigningPublicKey) getOperationSigningKey = nullptr;
  decltype(&WebAuthNPluginFreePublicKeyResponse) freePublicKey = nullptr;
  decltype(&WebAuthNDecodeMakeCredentialRequest) decodeMakeCredential = nullptr;
  decltype(&WebAuthNFreeDecodedMakeCredentialRequest) freeMakeCredential = nullptr;
  decltype(&WebAuthNDecodeGetAssertionRequest) decodeGetAssertion = nullptr;
  decltype(&WebAuthNFreeDecodedGetAssertionRequest) freeGetAssertion = nullptr;
  decltype(&WebAuthNEncodeMakeCredentialResponse) encodeMakeCredential = nullptr;
  decltype(&WebAuthNEncodeGetAssertionResponse) encodeGetAssertion = nullptr;

  /// The functions of this Windows; throws PluginError (notSupported) when
  /// webauthn.dll lacks one (a Windows older than 11 24H2).
  static const WebAuthnApi &load();
};

/// The plugin's class id.
const GUID &pluginClsid();

/// UTF-8 of [w], and back.
std::string utf8Of(const wchar_t *w);
std::wstring wideOf(const std::string &s);

/// The core's input of a decoded request.
MakeCredentialInput makeCredentialInputOf(const WEBAUTHN_CTAPCBOR_MAKE_CREDENTIAL_REQUEST &r);
GetAssertionInput getAssertionInputOf(const WEBAUTHN_CTAPCBOR_GET_ASSERTION_REQUEST &r);

/// The core's output encoded for Windows (CTAP2 CBOR); the buffer is the
/// encoder's (CoTaskMem), handed to Windows in the operation's response.
HRESULT encodeMakeCredential(const WebAuthnApi &api, const MakeCredentialOutput &out, DWORD *cb, BYTE **pb);
HRESULT encodeGetAssertion(const WebAuthnApi &api, const GetAssertionOutput &out, DWORD *cb, BYTE **pb);

/// Whether [signature] is Windows' signature of [data] (an operation
/// request) with the plugin's operation-signing key: SHA-256 of the data,
/// ECDSA (raw r||s, or DER) or RSA-PSS.
bool verifyRequestSignature(const WebAuthnApi &api, const BYTE *data, DWORD cbData, const BYTE *signature,
                            DWORD cbSignature);

/// The HRESULT a failure answers Windows.
HRESULT hresultOf(Failure failure);

} // namespace tsm_plugin
