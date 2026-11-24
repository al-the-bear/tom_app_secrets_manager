// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause
//
// tsm-passkey-plugin.exe: with -PluginActivated (Windows' activation, the
// package manifest's ExeServer arguments) the COM server; otherwise the
// commands the app runs:
//
//   --register          add the plugin to Windows (WebAuthNPluginAddAuthenticator)
//   --unregister        remove it, and the passkey names Windows keeps
//   --state             print enabled, disabled or not-registered
//   --sync-credentials  replace the passkey names Windows lists with the
//                       lines on standard input (never a key)
//
// Each command prints one line and exits 0, or prints the failure on
// standard error and exits 1.
#include <windows.h>
#include <shellapi.h>
#include <wincrypt.h>

#include <cstdio>
#include <iostream>
#include <iterator>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "../client_service.h"
#include "authenticator.h"
#include "webauthn_api.h"

using namespace tsm_plugin;

namespace {

const wchar_t *const authenticatorName = L"Tom Secrets Manager";

// The relying party of a WebAuthn call the plugin itself would make; the
// plugin makes none, but Windows asks for one.
const wchar_t *const pluginRpId = L"enterprise-flutter.dev";

// The product's shield, in the light and dark theme.
const char *const logoLight =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\">"
    "<path d=\"M32 4 8 13v17c0 15 10 26 24 30 14-4 24-15 24-30V13z\" fill=\"#1f5fa8\"/>"
    "<path d=\"M27 30v-5a5 5 0 0 1 10 0v5h3v14H24V30zm3 0h4v-5a2 2 0 0 0-4 0z\" fill=\"#fff\"/></svg>";
const char *const logoDark =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\">"
    "<path d=\"M32 4 8 13v17c0 15 10 26 24 30 14-4 24-15 24-30V13z\" fill=\"#8fbcf0\"/>"
    "<path d=\"M27 30v-5a5 5 0 0 1 10 0v5h3v14H24V30zm3 0h4v-5a2 2 0 0 0-4 0z\" fill=\"#10243c\"/></svg>";

void out(const std::string &line) {
  DWORD written = 0;
  const std::string text = line + "\r\n";
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
}

int fail(const std::string &message) {
  DWORD written = 0;
  const std::string text = "tsm-passkey-plugin: " + message + "\r\n";
  WriteFile(GetStdHandle(STD_ERROR_HANDLE), text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
  return 1;
}

std::string hex(HRESULT hr) {
  char buf[16];
  std::snprintf(buf, sizeof buf, "0x%08lX", static_cast<unsigned long>(hr));
  return buf;
}

std::wstring base64Of(const std::string &text) {
  DWORD n = 0;
  const auto *data = reinterpret_cast<const BYTE *>(text.data());
  const DWORD flags = CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF;
  CryptBinaryToStringW(data, static_cast<DWORD>(text.size()), flags, nullptr, &n);
  std::wstring out(n, L'\0');
  CryptBinaryToStringW(data, static_cast<DWORD>(text.size()), flags, out.data(), &n);
  out.resize(n);
  return out;
}

std::string readStdin() {
  std::string text;
  char buf[4096];
  DWORD n = 0;
  const HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
  while (ReadFile(in, buf, sizeof buf, &n, nullptr) && n > 0) text.append(buf, n);
  return text;
}

int registerPlugin(const WebAuthnApi &api) {
  const Bytes info = authenticatorInfo();
  const std::wstring light = base64Of(logoLight);
  const std::wstring dark = base64Of(logoDark);
  WEBAUTHN_PLUGIN_ADD_AUTHENTICATOR_OPTIONS options{authenticatorName,
                                                    pluginClsid(),
                                                    pluginRpId,
                                                    light.c_str(),
                                                    dark.c_str(),
                                                    static_cast<DWORD>(info.size()),
                                                    info.data(),
                                                    0,
                                                    nullptr};
  PWEBAUTHN_PLUGIN_ADD_AUTHENTICATOR_RESPONSE response = nullptr;
  const HRESULT hr = api.addAuthenticator(&options, &response);
  if (response) api.freeAddResponse(response);
  if (hr == NTE_EXISTS || hr == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)) {
    out("registered");
    return 0;
  }
  if (FAILED(hr)) {
    if (hr == static_cast<HRESULT>(0x80073D54)) {
      return fail("Windows registers only a packaged plugin: install the app's MSIX (" + hex(hr) + ")");
    }
    return fail("Windows refused the registration (" + hex(hr) + ")");
  }
  out("registered");
  return 0;
}

int unregisterPlugin(const WebAuthnApi &api) {
  api.removeAllCredentials(pluginClsid());
  const HRESULT hr = api.removeAuthenticator(pluginClsid());
  if (FAILED(hr) && hr != NTE_NOT_FOUND && hr != HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) {
    return fail("Windows refused the removal (" + hex(hr) + ")");
  }
  out("not-registered");
  return 0;
}

int printState(const WebAuthnApi &api) {
  AUTHENTICATOR_STATE state = AuthenticatorState_Disabled;
  const HRESULT hr = api.getState(pluginClsid(), &state);
  if (FAILED(hr)) {
    out("not-registered");
    return 0;
  }
  out(state == AuthenticatorState_Enabled ? "enabled" : "disabled");
  return 0;
}

int syncCredentials(const WebAuthnApi &api) {
  std::vector<CredentialDetails> list;
  try {
    list = parseCredentialLines(readStdin());
  } catch (const std::exception &e) {
    return fail(std::string("the passkey list does not read: ") + e.what());
  }
  // Windows keeps the strings and bytes only during the call.
  struct Held {
    std::wstring rpId, rpName, userName, displayName;
  };
  std::vector<Held> held(list.size());
  std::vector<WEBAUTHN_PLUGIN_CREDENTIAL_DETAILS> details(list.size());
  for (size_t i = 0; i < list.size(); i++) {
    held[i] = {wideOf(list[i].rpId), wideOf(list[i].rpName), wideOf(list[i].userName),
               wideOf(list[i].displayName)};
    details[i].cbCredentialId = static_cast<DWORD>(list[i].credentialId.size());
    details[i].pbCredentialId = list[i].credentialId.data();
    details[i].pwszRpId = held[i].rpId.c_str();
    details[i].pwszRpName = held[i].rpName.c_str();
    details[i].cbUserId = static_cast<DWORD>(list[i].userId.size());
    details[i].pbUserId = list[i].userId.data();
    details[i].pwszUserName = held[i].userName.c_str();
    details[i].pwszUserDisplayName = held[i].displayName.c_str();
  }
  HRESULT hr = api.removeAllCredentials(pluginClsid());
  if (FAILED(hr) && hr != NTE_NOT_FOUND && hr != HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) {
    return fail("Windows refused to clear the passkey list (" + hex(hr) + ")");
  }
  if (!details.empty()) {
    hr = api.addCredentials(pluginClsid(), static_cast<DWORD>(details.size()), details.data());
    if (FAILED(hr)) return fail("Windows refused the passkey list (" + hex(hr) + ")");
  }
  out("synced " + std::to_string(details.size()));
  return 0;
}

} // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  int argc = 0;
  LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  const std::wstring command = argc > 1 ? argv[1] : L"";
  LocalFree(argv);

  if (command == L"-PluginActivated") {
    return serve([] { return std::unique_ptr<PasskeyService>(new ClientService()); });
  }
  try {
    const WebAuthnApi &api = WebAuthnApi::load();
    if (command == L"--register") return registerPlugin(api);
    if (command == L"--unregister") return unregisterPlugin(api);
    if (command == L"--state") return printState(api);
    if (command == L"--sync-credentials") return syncCredentials(api);
  } catch (const PluginError &e) {
    return fail(e.what());
  }
  return fail("usage: tsm-passkey-plugin --register | --unregister | --state | --sync-credentials");
}
