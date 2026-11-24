// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause
//
// The plugin's core against a fake service: what a decoded CTAP2 request
// asks the service, and what its answers become.
#include <cstdio>

#include "fake_service.h"

using namespace tsm_plugin_test;

namespace {

Bytes hash32() { return Bytes(32, 0x11); }

void testBase64url() {
  CHECK(base64url({}) == "");
  CHECK(base64url({0xfb, 0xff}) == "-_8");
  CHECK(base64url({1, 2, 3, 4}) == "AQIDBA");
  CHECK(fromBase64url("AQIDBA") == (Bytes{1, 2, 3, 4}));
  CHECK(fromBase64url("-_8") == (Bytes{0xfb, 0xff}));
  CHECK(fromBase64url("+/8=") == (Bytes{0xfb, 0xff}));
  bool threw = false;
  try {
    fromBase64url("a*b");
  } catch (const std::invalid_argument &) {
    threw = true;
  }
  CHECK(threw);
}

void testMakeCredential() {
  FakeService s;
  MakeCredentialInput in{"webauthn.io", hash32(), {9, 9}, "demo", "Demo User", {-8, -7}, {{5, 6}}};
  const auto out = makeCredential(s, in);
  CHECK(s.calls.size() == 1 && s.calls[0] == "passkeyCreate webauthn.io");
  CHECK(s.lastCreate.url == "https://webauthn.io/");
  CHECK(s.lastCreate.userId == (Bytes{9, 9}));
  CHECK(s.lastCreate.userName == "demo");
  CHECK(s.lastCreate.displayName == "Demo User");
  CHECK(s.lastCreate.algorithms == (std::vector<int>{-8, -7}));
  CHECK(s.lastCreate.exclude == (std::vector<std::string>{"BQY"}));
  CHECK(out.credentialId == (Bytes{5, 6, 7, 8}));
  CHECK(out.authenticatorData == fromBase64url("SZYN5YgORQ"));

  // No algorithm named: ES256, which every site takes.
  in.algorithms.clear();
  makeCredential(s, in);
  CHECK(s.lastCreate.algorithms == (std::vector<int>{-7}));

  // A passkey the site holds already, the user's no, a malformed request.
  in.exclude = {{1, 2, 3, 4}};
  CHECK(throwsFailure([&] { makeCredential(s, in); }, Failure::excluded));
  in.exclude.clear();
  s.refuseCreate = true;
  CHECK(throwsFailure([&] { makeCredential(s, in); }, Failure::cancelled));
  in.clientDataHash = Bytes(31, 0);
  CHECK(throwsFailure([&] { makeCredential(s, in); }, Failure::other));
}

void testGetAssertion() {
  FakeService s;
  s.held.push_back({"Shared/~77aa", "webauthn.io", "other", "CQoL"});
  GetAssertionInput in{"webauthn.io", hash32(), {{9, 10, 11}}};
  const auto out = getAssertion(s, in);
  CHECK(s.calls.size() == 2);
  CHECK(s.calls[0] == "passkeys webauthn.io");
  CHECK(s.lastWait);
  CHECK(s.lastAllow == (std::vector<std::string>{"CQoL"}));
  CHECK(s.calls[1] == "passkeyGet webauthn.io Shared/~77aa");
  CHECK(s.lastHash == hash32());
  CHECK(s.lastUrl == "https://webauthn.io/");
  CHECK(out.credentialId == (Bytes{9, 10, 11}));
  CHECK(out.userHandle == fromBase64url("dXNlci0x"));
  CHECK(out.signature == fromBase64url("MEUCIQ"));

  // Without an allow list the site's first; a site without one is refused.
  in.allow.clear();
  getAssertion(s, in);
  CHECK(s.calls.back() == "passkeyGet webauthn.io Personal/~0f1e");
  in.rpId = "example.com";
  CHECK(throwsFailure([&] { getAssertion(s, in); }, Failure::notAllowed));
  s.locked = true;
  in.rpId = "webauthn.io";
  CHECK(throwsFailure([&] { getAssertion(s, in); }, Failure::locked));
}

void testUnlocked() {
  FakeService s;
  CHECK(unlocked(s));
  CHECK(s.calls.back() == "passkeys tom-secrets.invalid");
  CHECK(!s.lastWait);
  s.locked = true;
  CHECK(!unlocked(s));
}

void testCredentialLines() {
  const std::string text = "AQIDBA\td2ViYXV0aG4uaW8\td2ViYXV0aG4uaW8\tdXNlci0x\tZGVtbw\tRMOpbW8\r\n"
                           "\n"
                           "BQY\tZXhhbXBsZS5jb20\tRXhhbXBsZQ\tAQ\tYQ\t\n";
  const auto list = parseCredentialLines(text);
  CHECK(list.size() == 2);
  CHECK(list[0].credentialId == (Bytes{1, 2, 3, 4}));
  CHECK(list[0].rpId == "webauthn.io");
  CHECK(list[0].userId == fromBase64url("dXNlci0x"));
  CHECK(list[0].userName == "demo");
  CHECK(list[0].displayName == "D\xc3\xa9mo");
  CHECK(list[1].rpName == "Example");
  CHECK(list[1].displayName.empty());
  CHECK(parseCredentialLines("").empty());
  for (const char *bad : {"AQ\tYQ\n", "\tYQ\tYQ\tAQ\tYQ\tYQ\n", "AQ\tYQ\tYQ\tAQ\tY*\tYQ\n"}) {
    bool threw = false;
    try {
      parseCredentialLines(bad);
    } catch (const std::invalid_argument &) {
      threw = true;
    }
    CHECK(threw);
  }
}

void testAuthenticatorInfo() {
  const Bytes info = authenticatorInfo();
  // {1: ["FIDO_2_0", "FIDO_2_1"], 3: h'00…', 4: {rk, up, uv}, 9: ["internal"],
  //  10: [{alg: -7, type}, {alg: -8, type}]}
  CHECK(info.size() > 2 && info[0] == 0xa6 && info[1] == 0x01 && info[2] == 0x82);
  const std::string text(info.begin(), info.end());
  CHECK(text.find("FIDO_2_1") != std::string::npos);
  CHECK(text.find("internal") != std::string::npos);
  CHECK(text.find(std::string("\x03\x50", 2) + std::string(16, '\0')) != std::string::npos);
  CHECK(text.find(std::string("\x63" "alg" "\x26", 5)) != std::string::npos); // -7
  CHECK(text.find(std::string("\x63" "alg" "\x27", 5)) != std::string::npos); // -8
  CHECK(std::string(pluginClassId) == "c7185d2d-97da-4fd3-bec2-f615368a5ecf");
}

} // namespace

int main() {
  testBase64url();
  testMakeCredential();
  testGetAssertion();
  testUnlocked();
  testCredentialLines();
  testAuthenticatorInfo();
  std::printf("%d checks, %d failed\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
