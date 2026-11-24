// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause
//
// The plugin's COM authenticator against recorded CTAP2 requests (the
// requests Windows hands a plugin, as a browser's create() and get() make
// them) and a fake service: decoded and encoded by this Windows'
// webauthn.dll. The request signature is Windows' own and is not made here;
// these tests run the authenticator without its check.
#include <cstdio>
#include <string>

#include "fake_service.h"
#include "windows/authenticator.h"
#include "windows/webauthn_api.h"

using namespace tsm_plugin_test;

namespace {

// A small CBOR writer for the recorded requests (RFC 8949).
struct Cbor {
  Bytes out;
  Cbor &head(unsigned major, size_t n) {
    const auto m = static_cast<unsigned char>(major << 5);
    if (n < 24) {
      out.push_back(static_cast<unsigned char>(m | n));
    } else if (n < 0x100) {
      out.push_back(m | 24);
      out.push_back(static_cast<unsigned char>(n));
    } else {
      out.push_back(m | 25);
      out.push_back(static_cast<unsigned char>(n >> 8));
      out.push_back(static_cast<unsigned char>(n & 0xff));
    }
    return *this;
  }
  Cbor &map(size_t n) { return head(5, n); }
  Cbor &array(size_t n) { return head(4, n); }
  Cbor &integer(long long v) { return v >= 0 ? head(0, static_cast<size_t>(v)) : head(1, static_cast<size_t>(-1 - v)); }
  Cbor &text(const std::string &s) {
    head(3, s.size());
    out.insert(out.end(), s.begin(), s.end());
    return *this;
  }
  Cbor &bytes(const Bytes &b) {
    head(2, b.size());
    out.insert(out.end(), b.begin(), b.end());
    return *this;
  }
  Cbor &boolean(bool b) {
    out.push_back(b ? 0xf5 : 0xf4);
    return *this;
  }
  Cbor &credential(const Bytes &id) { return map(2).text("id").bytes(id).text("type").text("public-key"); }
};

const Bytes clientDataHash(32, 0x5a);

/// authenticatorMakeCredential of webauthn.io's "Register" (ES256 and
/// Ed25519, a resident key, one passkey excluded).
Bytes makeCredentialRequest() {
  Cbor c;
  c.map(6);
  c.integer(1).bytes(clientDataHash);
  c.integer(2).map(2).text("id").text("webauthn.io").text("name").text("webauthn.io");
  c.integer(3).map(3).text("id").bytes({0x64, 0x65, 0x6d, 0x6f}).text("name").text("demo").text("displayName").text(
      "Demo User");
  c.integer(4).array(2);
  c.map(2).text("alg").integer(-7).text("type").text("public-key");
  c.map(2).text("alg").integer(-8).text("type").text("public-key");
  c.integer(5).array(1).credential({0x05, 0x06});
  c.integer(7).map(1).text("rk").boolean(true);
  return c.out;
}

/// authenticatorGetAssertion of webauthn.io's "Authenticate" with the
/// passkey the user picked in Windows' dialog.
Bytes getAssertionRequest(const Bytes &allowed) {
  Cbor c;
  c.map(3);
  c.integer(1).text("webauthn.io");
  c.integer(2).bytes(clientDataHash);
  c.integer(3).array(1).credential(allowed);
  return c.out;
}

/// Windows hands a plugin the CTAP2 request's CBOR without the command
/// byte; webauthn.dll decodes that form.
void testDecoderForm(const WebAuthnApi &api) {
  const Bytes plain = makeCredentialRequest();
  PWEBAUTHN_CTAPCBOR_MAKE_CREDENTIAL_REQUEST decoded = nullptr;
  const HRESULT hr =
      api.decodeMakeCredential(static_cast<DWORD>(plain.size()), const_cast<BYTE *>(plain.data()), &decoded);
  CHECK(SUCCEEDED(hr) && decoded);
  if (decoded) api.freeMakeCredential(decoded);
}

WEBAUTHN_PLUGIN_OPERATION_REQUEST requestOf(Bytes &encoded, WEBAUTHN_PLUGIN_REQUEST_TYPE type) {
  WEBAUTHN_PLUGIN_OPERATION_REQUEST r{};
  r.requestType = type;
  r.cbEncodedRequest = static_cast<DWORD>(encoded.size());
  r.pbEncodedRequest = encoded.data();
  return r;
}

std::string textOf(const WEBAUTHN_PLUGIN_OPERATION_RESPONSE &r) {
  return std::string(reinterpret_cast<const char *>(r.pbEncodedResponse), r.cbEncodedResponse);
}

void testMakeCredential() {
  FakeService *fake = nullptr;
  auto *a = new Authenticator(
      [&] {
        auto s = std::make_unique<FakeService>();
        fake = s.get();
        return std::unique_ptr<PasskeyService>(std::move(s));
      },
      false);
  // The fake lives as long as the call; what it was asked is copied out.
  CreateRequest asked;
  auto *b = new Authenticator(
      [&] {
        struct Recording : FakeService {
          CreateRequest *into = nullptr;
          ~Recording() override { *into = lastCreate; }
        };
        auto s = std::make_unique<Recording>();
        s->into = &asked;
        return std::unique_ptr<PasskeyService>(std::move(s));
      },
      false);
  Bytes encoded = makeCredentialRequest();
  auto request = requestOf(encoded, WEBAUTHN_PLUGIN_REQUEST_TYPE_CTAP2_CBOR);
  WEBAUTHN_PLUGIN_OPERATION_RESPONSE response{};
  CHECK(b->MakeCredential(&request, &response) == S_OK);
  CHECK(asked.rpId == "webauthn.io");
  CHECK(asked.url == "https://webauthn.io/");
  CHECK(asked.userId == (Bytes{0x64, 0x65, 0x6d, 0x6f}));
  CHECK(asked.userName == "demo");
  CHECK(asked.displayName == "Demo User");
  CHECK(asked.algorithms == (std::vector<int>{-7, -8}));
  CHECK(asked.exclude == (std::vector<std::string>{"BQY"}));
  // The CTAP2 answer: {1: "none", 2: authData, 3: {}}.
  CHECK(response.cbEncodedResponse > 0 && response.pbEncodedResponse);
  const std::string answer = textOf(response);
  CHECK(answer.find("none") != std::string::npos);
  const Bytes authData = fromBase64url("SZYN5YgORQ");
  CHECK(answer.find(std::string(authData.begin(), authData.end())) != std::string::npos);
  CoTaskMemFree(response.pbEncodedResponse);
  b->Release();

  // A passkey the site holds already: NTE_EXISTS, which Windows answers
  // the site as InvalidStateError.
  Bytes excluded;
  {
    Cbor c;
    c.map(5);
    c.integer(1).bytes(clientDataHash);
    c.integer(2).map(1).text("id").text("webauthn.io");
    c.integer(3).map(2).text("id").bytes({1}).text("name").text("demo");
    c.integer(4).array(1).map(2).text("alg").integer(-7).text("type").text("public-key");
    c.integer(5).array(1).credential({1, 2, 3, 4});
    excluded = c.out;
  }
  request = requestOf(excluded, WEBAUTHN_PLUGIN_REQUEST_TYPE_CTAP2_CBOR);
  response = {};
  CHECK(a->MakeCredential(&request, &response) == NTE_EXISTS);
  CHECK(fake != nullptr);
  a->Release();
}

void testGetAssertion() {
  std::vector<std::string> allow;
  Bytes hash;
  auto *a = new Authenticator(
      [&] {
        struct Recording : FakeService {
          std::vector<std::string> *allow = nullptr;
          Bytes *hash = nullptr;
          ~Recording() override {
            *allow = lastAllow;
            *hash = lastHash;
          }
        };
        auto s = std::make_unique<Recording>();
        s->allow = &allow;
        s->hash = &hash;
        return std::unique_ptr<PasskeyService>(std::move(s));
      },
      false);
  Bytes encoded = getAssertionRequest({1, 2, 3, 4});
  auto request = requestOf(encoded, WEBAUTHN_PLUGIN_REQUEST_TYPE_CTAP2_CBOR);
  WEBAUTHN_PLUGIN_OPERATION_RESPONSE response{};
  CHECK(a->GetAssertion(&request, &response) == S_OK);
  CHECK(allow == (std::vector<std::string>{"AQIDBA"}));
  CHECK(hash == clientDataHash);
  const std::string answer = textOf(response);
  const Bytes signature = fromBase64url("MEUCIQ");
  const Bytes user = fromBase64url("dXNlci0x");
  CHECK(answer.find(std::string(signature.begin(), signature.end())) != std::string::npos);
  CHECK(answer.find(std::string(user.begin(), user.end())) != std::string::npos);
  CHECK(answer.find(std::string("\x01\x02\x03\x04", 4)) != std::string::npos);
  CoTaskMemFree(response.pbEncodedResponse);

  // A passkey the vaults do not hold: the user's cancel to Windows.
  Bytes unknown = getAssertionRequest({7, 7});
  request = requestOf(unknown, WEBAUTHN_PLUGIN_REQUEST_TYPE_CTAP2_CBOR);
  response = {};
  CHECK(a->GetAssertion(&request, &response) == NTE_USER_CANCELLED);

  // Garbage is refused by the decoder, never reaching the service.
  Bytes garbage{0xff, 0x00, 0x13};
  request = requestOf(garbage, WEBAUTHN_PLUGIN_REQUEST_TYPE_CTAP2_CBOR);
  response = {};
  CHECK(FAILED(a->GetAssertion(&request, &response)));
  a->Release();
}

void testLockStatus() {
  bool locked = false;
  auto *a = new Authenticator(
      [&] {
        auto s = std::make_unique<FakeService>();
        s->locked = locked;
        return std::unique_ptr<PasskeyService>(std::move(s));
      },
      false);
  PLUGIN_LOCK_STATUS status = PluginLocked;
  CHECK(a->GetLockStatus(&status) == S_OK && status == PluginUnlocked);
  locked = true;
  CHECK(a->GetLockStatus(&status) == S_OK && status == PluginLocked);
  a->Release();
}

void testSignatureChecked() {
  // With the check on, a request Windows did not sign is refused before it
  // is decoded (the plugin is not registered here: there is no key).
  auto *a = new Authenticator([] { return std::unique_ptr<PasskeyService>(new FakeService()); }, true);
  Bytes encoded = getAssertionRequest({1, 2, 3, 4});
  auto request = requestOf(encoded, WEBAUTHN_PLUGIN_REQUEST_TYPE_CTAP2_CBOR);
  BYTE forged[64] = {1};
  request.cbRequestSignature = sizeof forged;
  request.pbRequestSignature = forged;
  WEBAUTHN_PLUGIN_OPERATION_RESPONSE response{};
  CHECK(a->GetAssertion(&request, &response) == NTE_BAD_SIGNATURE);
  CHECK(response.pbEncodedResponse == nullptr);
  a->Release();
}

} // namespace

int main() {
  const WebAuthnApi *api = nullptr;
  try {
    api = &WebAuthnApi::load();
  } catch (const PluginError &e) {
    std::printf("skipped: %s\n", e.what());
    return 0;
  }
  testDecoderForm(*api);
  testMakeCredential();
  testGetAssertion();
  testLockStatus();
  testSignatureChecked();
  std::printf("%d checks, %d failed\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
