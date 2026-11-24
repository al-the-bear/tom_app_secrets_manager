// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

#include "authenticator.h"

#include <shlobj.h>

#include <cstdio>
#include <ctime>
#include <string>

#include "webauthn_api.h"

namespace tsm_plugin {

std::atomic<long> Authenticator::active{0};
std::atomic<ULONGLONG> Authenticator::lastActivity{0};

void logLine(const std::string &line) {
  PWSTR base = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &base))) return;
  std::wstring dir = std::wstring(base) + L"\\TomSecretsManager";
  CoTaskMemFree(base);
  CreateDirectoryW(dir.c_str(), nullptr);
  FILE *f = _wfopen((dir + L"\\passkey-plugin.log").c_str(), L"a");
  if (!f) return;
  std::time_t now = std::time(nullptr);
  char stamp[32];
  std::tm tm{};
  gmtime_s(&tm, &now);
  std::strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", &tm);
  std::fprintf(f, "%s %s\n", stamp, line.c_str());
  std::fclose(f);
}

namespace {

/// Counts a request while it runs.
struct Activity {
  Activity() { ++Authenticator::active; }
  ~Activity() {
    Authenticator::lastActivity = GetTickCount64();
    --Authenticator::active;
  }
};

HRESULT failed(const char *op, const PluginError &e) {
  logLine(std::string(op) + " refused: " + e.what());
  return hresultOf(e.failure);
}

} // namespace

Authenticator::Authenticator(ServiceFactory factory, bool verifySignatures)
    : factory_(std::move(factory)), verify_(verifySignatures) {}

HRESULT Authenticator::QueryInterface(REFIID riid, void **out) {
  if (!out) return E_POINTER;
  if (riid == IID_IUnknown || riid == __uuidof(IPluginAuthenticator)) {
    *out = static_cast<IPluginAuthenticator *>(this);
    AddRef();
    return S_OK;
  }
  *out = nullptr;
  return E_NOINTERFACE;
}

ULONG Authenticator::AddRef() { return ++refs_; }

ULONG Authenticator::Release() {
  const ULONG n = --refs_;
  if (n == 0) delete this;
  return n;
}

HRESULT Authenticator::MakeCredential(PCWEBAUTHN_PLUGIN_OPERATION_REQUEST request,
                                      PWEBAUTHN_PLUGIN_OPERATION_RESPONSE response) {
  Activity activity;
  if (!request || !response || !request->pbEncodedRequest) return E_INVALIDARG;
  try {
    const WebAuthnApi &api = WebAuthnApi::load();
    if (verify_ && !verifyRequestSignature(api, request->pbEncodedRequest, request->cbEncodedRequest,
                                           request->pbRequestSignature, request->cbRequestSignature)) {
      logLine("MakeCredential refused: the request's signature does not verify");
      return NTE_BAD_SIGNATURE;
    }
    PWEBAUTHN_CTAPCBOR_MAKE_CREDENTIAL_REQUEST decoded = nullptr;
    HRESULT hr = api.decodeMakeCredential(request->cbEncodedRequest, request->pbEncodedRequest, &decoded);
    if (FAILED(hr) || !decoded) return FAILED(hr) ? hr : E_FAIL;
    MakeCredentialInput in = makeCredentialInputOf(*decoded);
    api.freeMakeCredential(decoded);
    const MakeCredentialOutput out = makeCredential(*factory_(), in);
    hr = encodeMakeCredential(api, out, &response->cbEncodedResponse, &response->pbEncodedResponse);
    if (FAILED(hr)) logLine("MakeCredential: encoding the answer failed");
    return hr;
  } catch (const PluginError &e) {
    return failed("MakeCredential", e);
  } catch (const std::exception &e) {
    logLine(std::string("MakeCredential failed: ") + e.what());
    return E_FAIL;
  }
}

HRESULT Authenticator::GetAssertion(PCWEBAUTHN_PLUGIN_OPERATION_REQUEST request,
                                    PWEBAUTHN_PLUGIN_OPERATION_RESPONSE response) {
  Activity activity;
  if (!request || !response || !request->pbEncodedRequest) return E_INVALIDARG;
  try {
    const WebAuthnApi &api = WebAuthnApi::load();
    if (verify_ && !verifyRequestSignature(api, request->pbEncodedRequest, request->cbEncodedRequest,
                                           request->pbRequestSignature, request->cbRequestSignature)) {
      logLine("GetAssertion refused: the request's signature does not verify");
      return NTE_BAD_SIGNATURE;
    }
    PWEBAUTHN_CTAPCBOR_GET_ASSERTION_REQUEST decoded = nullptr;
    HRESULT hr = api.decodeGetAssertion(request->cbEncodedRequest, request->pbEncodedRequest, &decoded);
    if (FAILED(hr) || !decoded) return FAILED(hr) ? hr : E_FAIL;
    GetAssertionInput in = getAssertionInputOf(*decoded);
    api.freeGetAssertion(decoded);
    const GetAssertionOutput out = getAssertion(*factory_(), in);
    hr = encodeGetAssertion(api, out, &response->cbEncodedResponse, &response->pbEncodedResponse);
    if (FAILED(hr)) logLine("GetAssertion: encoding the answer failed");
    return hr;
  } catch (const PluginError &e) {
    return failed("GetAssertion", e);
  } catch (const std::exception &e) {
    logLine(std::string("GetAssertion failed: ") + e.what());
    return E_FAIL;
  }
}

HRESULT Authenticator::CancelOperation(PCWEBAUTHN_PLUGIN_CANCEL_OPERATION_REQUEST) {
  // The service ends a request it is asking the user about when the user
  // answers or its approval times out; nothing is held here to cancel.
  return S_OK;
}

HRESULT Authenticator::GetLockStatus(PLUGIN_LOCK_STATUS *lockStatus) {
  Activity activity;
  if (!lockStatus) return E_POINTER;
  try {
    *lockStatus = unlocked(*factory_()) ? PluginUnlocked : PluginLocked;
  } catch (...) {
    *lockStatus = PluginLocked;
  }
  return S_OK;
}

AuthenticatorFactory::AuthenticatorFactory(ServiceFactory factory) : factory_(std::move(factory)) {}

HRESULT AuthenticatorFactory::QueryInterface(REFIID riid, void **out) {
  if (!out) return E_POINTER;
  if (riid == IID_IUnknown || riid == IID_IClassFactory) {
    *out = static_cast<IClassFactory *>(this);
    AddRef();
    return S_OK;
  }
  *out = nullptr;
  return E_NOINTERFACE;
}

ULONG AuthenticatorFactory::AddRef() { return ++refs_; }

ULONG AuthenticatorFactory::Release() {
  const ULONG n = --refs_;
  if (n == 0) delete this;
  return n;
}

HRESULT AuthenticatorFactory::CreateInstance(IUnknown *outer, REFIID riid, void **out) {
  if (outer) return CLASS_E_NOAGGREGATION;
  auto *a = new (std::nothrow) Authenticator(factory_);
  if (!a) return E_OUTOFMEMORY;
  const HRESULT hr = a->QueryInterface(riid, out);
  a->Release();
  return hr;
}

HRESULT AuthenticatorFactory::LockServer(BOOL) { return S_OK; }

int serve(ServiceFactory factory, DWORD idleMs) {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(hr)) return 1;
  CoInitializeSecurity(nullptr, -1, nullptr, nullptr, RPC_C_AUTHN_LEVEL_DEFAULT, RPC_C_IMP_LEVEL_IMPERSONATE,
                       nullptr, EOAC_NONE, nullptr);
  auto *f = new AuthenticatorFactory(std::move(factory));
  DWORD cookie = 0;
  hr = CoRegisterClassObject(pluginClsid(), f, CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, &cookie);
  f->Release();
  if (FAILED(hr)) {
    logLine("the class could not be registered with COM");
    CoUninitialize();
    return 1;
  }
  Authenticator::lastActivity = GetTickCount64();
  for (;;) {
    Sleep(1000);
    if (Authenticator::active == 0 && GetTickCount64() - Authenticator::lastActivity > idleMs) break;
  }
  CoRevokeClassObject(cookie);
  CoUninitialize();
  return 0;
}

} // namespace tsm_plugin
