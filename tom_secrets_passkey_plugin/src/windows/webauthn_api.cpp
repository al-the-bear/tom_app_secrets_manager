// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

#include "webauthn_api.h"

#include <bcrypt.h>
#include <ncrypt.h>

#include <vector>

namespace tsm_plugin {

namespace {

template <typename F> void loadInto(HMODULE dll, const char *name, F &out) {
  out = reinterpret_cast<F>(reinterpret_cast<void *>(GetProcAddress(dll, name)));
  if (!out) throw PluginError(Failure::notSupported, std::string("webauthn.dll has no ") + name);
}

Bytes bytesOf(const BYTE *p, DWORD n) { return p && n ? Bytes(p, p + n) : Bytes(); }

/// DER ECDSA (SEQUENCE of two INTEGERs) as raw r||s of [half] bytes each;
/// empty when it is not DER.
Bytes rawOfDer(const BYTE *der, DWORD n, DWORD half) {
  if (n < 8 || der[0] != 0x30) return {};
  DWORD i = 2;
  Bytes out;
  for (int k = 0; k < 2; k++) {
    if (i + 2 > n || der[i] != 0x02) return {};
    DWORD len = der[i + 1];
    i += 2;
    if (i + len > n) return {};
    const BYTE *v = der + i;
    while (len > half && *v == 0) {
      v++;
      len--;
    }
    if (len > half) return {};
    out.insert(out.end(), half - len, 0);
    out.insert(out.end(), v, v + len);
    i += len;
  }
  return out;
}

} // namespace

const GUID &pluginClsid() {
  // c7185d2d-97da-4fd3-bec2-f615368a5ecf (core.cpp's pluginClassId, the
  // package manifest's com:Class).
  static const GUID id = {0xc7185d2d, 0x97da, 0x4fd3, {0xbe, 0xc2, 0xf6, 0x15, 0x36, 0x8a, 0x5e, 0xcf}};
  return id;
}

const WebAuthnApi &WebAuthnApi::load() {
  static WebAuthnApi api;
  static bool loaded = false;
  if (loaded) return api;
  HMODULE dll = LoadLibraryExW(L"webauthn.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!dll) throw PluginError(Failure::notSupported, "no webauthn.dll");
  loadInto(dll, "WebAuthNPluginAddAuthenticator", api.addAuthenticator);
  loadInto(dll, "WebAuthNPluginFreeAddAuthenticatorResponse", api.freeAddResponse);
  loadInto(dll, "WebAuthNPluginRemoveAuthenticator", api.removeAuthenticator);
  loadInto(dll, "WebAuthNPluginGetAuthenticatorState", api.getState);
  loadInto(dll, "WebAuthNPluginAuthenticatorAddCredentials", api.addCredentials);
  loadInto(dll, "WebAuthNPluginAuthenticatorRemoveAllCredentials", api.removeAllCredentials);
  loadInto(dll, "WebAuthNPluginGetOperationSigningPublicKey", api.getOperationSigningKey);
  loadInto(dll, "WebAuthNPluginFreePublicKeyResponse", api.freePublicKey);
  loadInto(dll, "WebAuthNDecodeMakeCredentialRequest", api.decodeMakeCredential);
  loadInto(dll, "WebAuthNFreeDecodedMakeCredentialRequest", api.freeMakeCredential);
  loadInto(dll, "WebAuthNDecodeGetAssertionRequest", api.decodeGetAssertion);
  loadInto(dll, "WebAuthNFreeDecodedGetAssertionRequest", api.freeGetAssertion);
  loadInto(dll, "WebAuthNEncodeMakeCredentialResponse", api.encodeMakeCredential);
  loadInto(dll, "WebAuthNEncodeGetAssertionResponse", api.encodeGetAssertion);
  loaded = true;
  return api;
}

std::string utf8Of(const wchar_t *w) {
  if (!w || !*w) return {};
  const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  std::string out(static_cast<size_t>(n > 0 ? n - 1 : 0), '\0');
  if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w, -1, out.data(), n, nullptr, nullptr);
  return out;
}

std::wstring wideOf(const std::string &s) {
  if (s.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), out.data(), n);
  return out;
}

MakeCredentialInput makeCredentialInputOf(const WEBAUTHN_CTAPCBOR_MAKE_CREDENTIAL_REQUEST &r) {
  MakeCredentialInput in;
  if (r.pbRpId && r.cbRpId) {
    in.rpId.assign(reinterpret_cast<const char *>(r.pbRpId), r.cbRpId);
  } else if (r.pRpInformation) {
    in.rpId = utf8Of(r.pRpInformation->pwszId);
  }
  in.clientDataHash = bytesOf(r.pbClientDataHash, r.cbClientDataHash);
  if (r.pUserInformation) {
    in.userId = bytesOf(r.pUserInformation->pbId, r.pUserInformation->cbId);
    in.userName = utf8Of(r.pUserInformation->pwszName);
    in.displayName = utf8Of(r.pUserInformation->pwszDisplayName);
  }
  for (DWORD i = 0; i < r.WebAuthNCredentialParameters.cCredentialParameters; i++) {
    in.algorithms.push_back(static_cast<int>(r.WebAuthNCredentialParameters.pCredentialParameters[i].lAlg));
  }
  for (DWORD i = 0; i < r.CredentialList.cCredentials; i++) {
    const auto *c = r.CredentialList.ppCredentials[i];
    if (c) in.exclude.push_back(bytesOf(c->pbId, c->cbId));
  }
  return in;
}

GetAssertionInput getAssertionInputOf(const WEBAUTHN_CTAPCBOR_GET_ASSERTION_REQUEST &r) {
  GetAssertionInput in;
  if (r.pbRpId && r.cbRpId) {
    in.rpId.assign(reinterpret_cast<const char *>(r.pbRpId), r.cbRpId);
  } else {
    in.rpId = utf8Of(r.pwszRpId);
  }
  in.clientDataHash = bytesOf(r.pbClientDataHash, r.cbClientDataHash);
  for (DWORD i = 0; i < r.CredentialList.cCredentials; i++) {
    const auto *c = r.CredentialList.ppCredentials[i];
    if (c) in.allow.push_back(bytesOf(c->pbId, c->cbId));
  }
  return in;
}

HRESULT encodeMakeCredential(const WebAuthnApi &api, const MakeCredentialOutput &out, DWORD *cb, BYTE **pb) {
  Bytes data = out.authenticatorData;
  Bytes id = out.credentialId;
  WEBAUTHN_CREDENTIAL_ATTESTATION a{};
  a.dwVersion = WEBAUTHN_CREDENTIAL_ATTESTATION_CURRENT_VERSION;
  a.pwszFormatType = WEBAUTHN_ATTESTATION_TYPE_NONE;
  a.cbAuthenticatorData = static_cast<DWORD>(data.size());
  a.pbAuthenticatorData = data.data();
  a.cbAttestation = 0;
  a.pbAttestation = nullptr;
  a.cbCredentialId = static_cast<DWORD>(id.size());
  a.pbCredentialId = id.data();
  return api.encodeMakeCredential(&a, cb, pb);
}

HRESULT encodeGetAssertion(const WebAuthnApi &api, const GetAssertionOutput &out, DWORD *cb, BYTE **pb) {
  Bytes data = out.authenticatorData;
  Bytes signature = out.signature;
  Bytes id = out.credentialId;
  Bytes user = out.userHandle;
  WEBAUTHN_USER_ENTITY_INFORMATION userInfo{};
  userInfo.dwVersion = WEBAUTHN_USER_ENTITY_INFORMATION_CURRENT_VERSION;
  userInfo.cbId = static_cast<DWORD>(user.size());
  userInfo.pbId = user.data();
  WEBAUTHN_CTAPCBOR_GET_ASSERTION_RESPONSE r{};
  r.WebAuthNAssertion.dwVersion = WEBAUTHN_ASSERTION_CURRENT_VERSION;
  r.WebAuthNAssertion.cbAuthenticatorData = static_cast<DWORD>(data.size());
  r.WebAuthNAssertion.pbAuthenticatorData = data.data();
  r.WebAuthNAssertion.cbSignature = static_cast<DWORD>(signature.size());
  r.WebAuthNAssertion.pbSignature = signature.data();
  r.WebAuthNAssertion.Credential.dwVersion = WEBAUTHN_CREDENTIAL_CURRENT_VERSION;
  r.WebAuthNAssertion.Credential.cbId = static_cast<DWORD>(id.size());
  r.WebAuthNAssertion.Credential.pbId = id.data();
  r.WebAuthNAssertion.Credential.pwszCredentialType = WEBAUTHN_CREDENTIAL_TYPE_PUBLIC_KEY;
  r.WebAuthNAssertion.cbUserId = static_cast<DWORD>(user.size());
  r.WebAuthNAssertion.pbUserId = user.empty() ? nullptr : user.data();
  r.pUserInformation = user.empty() ? nullptr : &userInfo;
  r.dwNumberOfCredentials = 1;
  return api.encodeGetAssertion(&r, cb, pb);
}

bool verifyRequestSignature(const WebAuthnApi &api, const BYTE *data, DWORD cbData, const BYTE *signature,
                            DWORD cbSignature) {
  DWORD cbKey = 0;
  PBYTE pbKey = nullptr;
  if (FAILED(api.getOperationSigningKey(pluginClsid(), &cbKey, &pbKey)) || !pbKey || !cbKey) return false;
  BYTE hash[32];
  bool ok = false;
  NCRYPT_PROV_HANDLE provider = 0;
  NCRYPT_KEY_HANDLE key = 0;
  if (BCRYPT_SUCCESS(BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0, const_cast<PUCHAR>(data), cbData, hash,
                                sizeof hash)) &&
      NCryptOpenStorageProvider(&provider, nullptr, 0) == ERROR_SUCCESS &&
      NCryptImportKey(provider, 0, BCRYPT_PUBLIC_KEY_BLOB, nullptr, &key, pbKey, cbKey, 0) == ERROR_SUCCESS) {
    const auto *header = reinterpret_cast<const BCRYPT_KEY_BLOB *>(pbKey);
    if (header->Magic == BCRYPT_RSAPUBLIC_MAGIC) {
      BCRYPT_PSS_PADDING_INFO pss{BCRYPT_SHA256_ALGORITHM, 32};
      ok = NCryptVerifySignature(key, &pss, hash, sizeof hash, const_cast<PBYTE>(signature), cbSignature,
                                 NCRYPT_PAD_PSS_FLAG) == ERROR_SUCCESS;
    } else {
      ok = NCryptVerifySignature(key, nullptr, hash, sizeof hash, const_cast<PBYTE>(signature), cbSignature, 0) ==
           ERROR_SUCCESS;
      if (!ok) {
        // An ECDSA signature given as DER: try it as raw r||s.
        const auto *ecc = reinterpret_cast<const BCRYPT_ECCKEY_BLOB *>(pbKey);
        Bytes raw = rawOfDer(signature, cbSignature, ecc->cbKey);
        ok = !raw.empty() && NCryptVerifySignature(key, nullptr, hash, sizeof hash, raw.data(),
                                                   static_cast<DWORD>(raw.size()), 0) == ERROR_SUCCESS;
      }
    }
  }
  if (key) NCryptFreeObject(key);
  if (provider) NCryptFreeObject(provider);
  api.freePublicKey(pbKey);
  return ok;
}

HRESULT hresultOf(Failure failure) {
  switch (failure) {
  case Failure::excluded:
    return NTE_EXISTS;
  case Failure::notSupported:
    return NTE_NOT_SUPPORTED;
  case Failure::cancelled:
  case Failure::notAllowed:
    return NTE_USER_CANCELLED;
  case Failure::locked:
  case Failure::notRunning:
    return NTE_DEVICE_NOT_READY;
  default:
    return E_FAIL;
  }
}

} // namespace tsm_plugin
