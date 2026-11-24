// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause
//
// A fake service for the plugin's tests: it answers as the service's
// passkey requests do (protocol.md 5.8) and records what it was asked.
#pragma once

#include <cstdio>
#include <string>
#include <vector>

#include "core.h"

namespace tsm_plugin_test {

using namespace tsm_plugin;

struct FakeService : PasskeyService {
  // What it holds.
  std::vector<Candidate> held{{"Personal/~0f1e", "webauthn.io", "demo-user", "AQIDBA"}};
  bool locked = false;
  bool refuseCreate = false;

  // What it was asked.
  std::vector<std::string> calls;
  std::vector<std::string> lastAllow;
  bool lastWait = false;
  CreateRequest lastCreate;
  Bytes lastHash;
  std::string lastUrl;

  std::vector<Candidate> passkeys(const std::string &url, const std::string &rpId,
                                  const std::vector<std::string> &allow, bool wait) override {
    calls.push_back("passkeys " + rpId);
    lastUrl = url;
    lastAllow = allow;
    lastWait = wait;
    if (locked) throw PluginError(Failure::locked, "the service is locked");
    std::vector<Candidate> out;
    if (rpId != "webauthn.io") return out;
    for (const auto &c : held) {
      bool ok = allow.empty();
      for (const auto &a : allow) ok = ok || a == c.credentialId;
      if (ok) out.push_back(c);
    }
    return out;
  }

  Signature sign(const std::string &url, const std::string &rpId, const std::string &entryId,
                 const Bytes &clientDataHash) override {
    calls.push_back("passkeyGet " + rpId + " " + entryId);
    lastUrl = url;
    lastHash = clientDataHash;
    for (const auto &c : held) {
      if (c.entryId == entryId) return {c.credentialId, "SZYN5YgO", "MEUCIQ", "dXNlci0x"};
    }
    throw PluginError(Failure::notAllowed, "no such passkey");
  }

  Created create(const CreateRequest &request) override {
    calls.push_back("passkeyCreate " + request.rpId);
    lastCreate = request;
    if (refuseCreate) throw PluginError(Failure::cancelled, "the user said no");
    for (const auto &e : request.exclude) {
      for (const auto &c : held) {
        if (c.credentialId == e) throw PluginError(Failure::excluded, "held already");
      }
    }
    return {"BQYHCA", "SZYN5YgORQ", "o2NmbXRkbm9uZQ", "pQECAyYg", -7};
  }
};

inline int failures = 0;
inline int checks = 0;

inline void check(bool ok, const char *what, int line) {
  checks++;
  if (!ok) {
    failures++;
    std::fprintf(stderr, "FAIL line %d: %s\n", line, what);
  }
}

#define CHECK(x) ::tsm_plugin_test::check((x), #x, __LINE__)

/// Whether [f] throws a PluginError of [failure].
template <typename F> bool throwsFailure(F f, Failure failure) {
  try {
    f();
  } catch (const PluginError &e) {
    return e.failure == failure;
  }
  return false;
}

} // namespace tsm_plugin_test
