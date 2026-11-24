// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

#include "core.h"

#include <cstdint>

namespace tsm_plugin {

const char *const pluginClassId = "c7185d2d-97da-4fd3-bec2-f615368a5ecf";

namespace {

const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

int valueOf(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '-' || c == '+') return 62;
  if (c == '_' || c == '/') return 63;
  return -1;
}

/// The reserved name the lock probe asks for (RFC 2606): no passkey holds
/// it.
const char probeRpId[] = "tom-secrets.invalid";

// A small CBOR writer for authenticatorGetInfo (RFC 8949).
void head(Bytes &out, unsigned major, std::uint64_t n) {
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
}

void text(Bytes &out, const std::string &s) {
  head(out, 3, s.size());
  out.insert(out.end(), s.begin(), s.end());
}

void integer(Bytes &out, long long v) {
  if (v >= 0) {
    head(out, 0, static_cast<std::uint64_t>(v));
  } else {
    head(out, 1, static_cast<std::uint64_t>(-1 - v));
  }
}

} // namespace

std::string base64url(const Bytes &bytes) {
  std::string out;
  std::size_t i = 0;
  for (; i + 2 < bytes.size(); i += 3) {
    const unsigned v = bytes[i] << 16 | bytes[i + 1] << 8 | bytes[i + 2];
    out += alphabet[v >> 18 & 63];
    out += alphabet[v >> 12 & 63];
    out += alphabet[v >> 6 & 63];
    out += alphabet[v & 63];
  }
  if (bytes.size() - i == 1) {
    const unsigned v = bytes[i] << 16;
    out += alphabet[v >> 18 & 63];
    out += alphabet[v >> 12 & 63];
  } else if (bytes.size() - i == 2) {
    const unsigned v = bytes[i] << 16 | bytes[i + 1] << 8;
    out += alphabet[v >> 18 & 63];
    out += alphabet[v >> 12 & 63];
    out += alphabet[v >> 6 & 63];
  }
  return out;
}

Bytes fromBase64url(const std::string &text) {
  Bytes out;
  unsigned buffer = 0;
  int bits = 0;
  for (char c : text) {
    if (c == '=') break;
    const int v = valueOf(c);
    if (v < 0) throw std::invalid_argument("not base64url");
    buffer = buffer << 6 | static_cast<unsigned>(v);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<unsigned char>(buffer >> bits & 0xff));
    }
  }
  if (bits >= 6) throw std::invalid_argument("not base64url");
  return out;
}

std::string pageUrlOf(const std::string &rpId) { return "https://" + rpId + "/"; }

MakeCredentialOutput makeCredential(PasskeyService &service, const MakeCredentialInput &in) {
  if (in.rpId.empty() || in.userId.empty() || in.clientDataHash.size() != 32) {
    throw PluginError(Failure::other, "the request names no relying party, user or client data");
  }
  CreateRequest request;
  request.url = pageUrlOf(in.rpId);
  request.rpId = in.rpId;
  request.userId = in.userId;
  request.userName = in.userName;
  request.displayName = in.displayName;
  request.algorithms = in.algorithms.empty() ? std::vector<int>{-7} : in.algorithms;
  for (const auto &id : in.exclude) request.exclude.push_back(base64url(id));
  const Created made = service.create(request);
  return {fromBase64url(made.authenticatorData), fromBase64url(made.credentialId)};
}

GetAssertionOutput getAssertion(PasskeyService &service, const GetAssertionInput &in) {
  if (in.rpId.empty() || in.clientDataHash.size() != 32) {
    throw PluginError(Failure::other, "the request names no relying party or client data");
  }
  std::vector<std::string> allow;
  for (const auto &id : in.allow) allow.push_back(base64url(id));
  const std::string url = pageUrlOf(in.rpId);
  const auto found = service.passkeys(url, in.rpId, allow, true);
  if (found.empty()) {
    throw PluginError(Failure::notAllowed, "no passkey of " + in.rpId + " in Tom Secrets Manager");
  }
  // Windows names the credential the user picked; without one, the site's
  // first (the service lists the exact host's first).
  const Candidate &picked = found.front();
  const Signature s = service.sign(url, in.rpId, picked.entryId, in.clientDataHash);
  GetAssertionOutput out;
  out.credentialId = fromBase64url(s.credentialId);
  out.authenticatorData = fromBase64url(s.authenticatorData);
  out.signature = fromBase64url(s.signature);
  if (!s.userHandle.empty()) out.userHandle = fromBase64url(s.userHandle);
  return out;
}

bool unlocked(PasskeyService &service) {
  try {
    service.passkeys(pageUrlOf(probeRpId), probeRpId, {}, false);
    return true;
  } catch (const PluginError &) {
    return false;
  }
}

std::vector<CredentialDetails> parseCredentialLines(const std::string &text) {
  std::vector<CredentialDetails> out;
  std::size_t start = 0;
  while (start <= text.size()) {
    std::size_t end = text.find('\n', start);
    if (end == std::string::npos) end = text.size();
    std::string line = text.substr(start, end - start);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    start = end + 1;
    if (line.empty()) continue;
    std::vector<std::string> fields;
    std::size_t from = 0;
    for (;;) {
      const std::size_t tab = line.find('\t', from);
      fields.push_back(line.substr(from, tab == std::string::npos ? std::string::npos : tab - from));
      if (tab == std::string::npos) break;
      from = tab + 1;
    }
    if (fields.size() != 6) throw std::invalid_argument("a credential line has six fields");
    auto textOf = [](const std::string &f) {
      const Bytes b = fromBase64url(f);
      return std::string(b.begin(), b.end());
    };
    CredentialDetails d;
    d.credentialId = fromBase64url(fields[0]);
    d.rpId = textOf(fields[1]);
    d.rpName = textOf(fields[2]);
    d.userId = fromBase64url(fields[3]);
    d.userName = textOf(fields[4]);
    d.displayName = textOf(fields[5]);
    if (d.credentialId.empty() || d.rpId.empty() || d.userId.empty()) {
      throw std::invalid_argument("a credential line names its id, relying party and user");
    }
    out.push_back(d);
  }
  return out;
}

Bytes authenticatorInfo() {
  Bytes out;
  head(out, 5, 6); // a map of six
  integer(out, 1);
  head(out, 4, 2);
  text(out, "FIDO_2_0");
  text(out, "FIDO_2_1");
  integer(out, 3);
  head(out, 2, 16);
  out.insert(out.end(), 16, 0);
  integer(out, 4);
  head(out, 5, 3);
  text(out, "rk");
  out.push_back(0xf5);
  text(out, "up");
  out.push_back(0xf5);
  text(out, "uv");
  out.push_back(0xf5);
  integer(out, 9);
  head(out, 4, 1);
  text(out, "internal");
  integer(out, 10);
  head(out, 4, 2);
  for (long long alg : {-7LL, -8LL}) {
    head(out, 5, 2);
    text(out, "alg");
    integer(out, alg);
    text(out, "type");
    text(out, "public-key");
  }
  return out;
}

} // namespace tsm_plugin
