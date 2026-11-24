// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause
//
// The plugin's COM server (IPluginAuthenticator): Windows starts it with
// -PluginActivated for a request, the package manifest naming it as the
// plugin's class. Each request's signature is verified with the
// operation-signing key, the request decoded, the service asked, the answer
// encoded. User verification is the service's (DP-120 decision (b)): the
// app confirms a new passkey; a sign-in asks the first time only, as the
// browser's does.
#pragma once

#include <windows.h>
#include <webauthn.h>
#include <webauthnplugin.h>
#include <pluginauthenticator.h>

#include <atomic>
#include <functional>
#include <memory>

#include "../core.h"

namespace tsm_plugin {

/// Makes the service a request talks to (the C client; a fake in tests).
using ServiceFactory = std::function<std::unique_ptr<PasskeyService>()>;

class Authenticator : public IPluginAuthenticator {
public:
  explicit Authenticator(ServiceFactory factory, bool verifySignatures = true);

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  // IPluginAuthenticator
  HRESULT STDMETHODCALLTYPE MakeCredential(PCWEBAUTHN_PLUGIN_OPERATION_REQUEST request,
                                           PWEBAUTHN_PLUGIN_OPERATION_RESPONSE response) override;
  HRESULT STDMETHODCALLTYPE GetAssertion(PCWEBAUTHN_PLUGIN_OPERATION_REQUEST request,
                                         PWEBAUTHN_PLUGIN_OPERATION_RESPONSE response) override;
  HRESULT STDMETHODCALLTYPE CancelOperation(PCWEBAUTHN_PLUGIN_CANCEL_OPERATION_REQUEST request) override;
  HRESULT STDMETHODCALLTYPE GetLockStatus(PLUGIN_LOCK_STATUS *lockStatus) override;

  /// The requests running now and the time of the last one's end (the
  /// server exits when it has been idle a while).
  static std::atomic<long> active;
  static std::atomic<ULONGLONG> lastActivity;

private:
  virtual ~Authenticator() = default;
  std::atomic<ULONG> refs_{1};
  ServiceFactory factory_;
  bool verify_;
};

/// The class factory CoRegisterClassObject registers.
class AuthenticatorFactory : public IClassFactory {
public:
  explicit AuthenticatorFactory(ServiceFactory factory);
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown *outer, REFIID riid, void **out) override;
  HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) override;

private:
  virtual ~AuthenticatorFactory() = default;
  std::atomic<ULONG> refs_{1};
  ServiceFactory factory_;
};

/// Runs the COM server until it has been idle for [idleMs].
int serve(ServiceFactory factory, DWORD idleMs = 60000);

/// Writes a line to the plugin's log (%LOCALAPPDATA%\TomSecretsManager\
/// passkey-plugin.log): what failed, never a value.
void logLine(const std::string &line);

} // namespace tsm_plugin
