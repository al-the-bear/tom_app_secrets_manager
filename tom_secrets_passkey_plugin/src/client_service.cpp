// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

#include "client_service.h"

#include <cstring>

#include <tsm/tsm.h>

namespace tsm_plugin {

namespace {

std::string owned(const char *s) { return s ? std::string(s) : std::string(); }

} // namespace

PluginError lastClientError() {
  const tsm_error *e = tsm_last_error(nullptr);
  const std::string message = owned(e->message);
  const std::string reason = owned(e->reason);
  switch (e->kind) {
  case TSM_ERR_LOCKED:
  case TSM_ERR_NEEDS_UNLOCK:
    return {Failure::locked, message};
  case TSM_ERR_NOT_RUNNING:
    return {Failure::notRunning, message};
  case TSM_ERR_UNSUPPORTED:
    return {Failure::notSupported, message};
  case TSM_ERR_TIMEOUT:
    return {Failure::cancelled, message};
  case TSM_ERR_DENIED:
    if (reason == "excluded") return {Failure::excluded, message};
    if (reason == "refused" || reason == "timeout" || reason == "no_approver") {
      return {Failure::cancelled, message};
    }
    return {Failure::notAllowed, message};
  default:
    return {Failure::other, message};
  }
}

ClientService::ClientService() {
  tsm_client_options options = TSM_CLIENT_OPTIONS_INIT;
  options.client_name = "tsm-passkey-plugin";
  if (tsm_client_new(&client_, &options) != TSM_OK) throw lastClientError();
}

ClientService::~ClientService() { tsm_client_free(client_); }

std::vector<Candidate> ClientService::passkeys(const std::string &url, const std::string &rpId,
                                               const std::vector<std::string> &allow, bool wait) {
  std::vector<const char *> ids;
  for (const auto &a : allow) ids.push_back(a.c_str());
  tsm_passkey *list = nullptr;
  std::size_t count = 0;
  if (tsm_passkeys(client_, url.c_str(), rpId.c_str(), ids.empty() ? nullptr : ids.data(), ids.size(),
                   wait ? 0 : 1, &list, &count) != TSM_OK) {
    throw lastClientError();
  }
  std::vector<Candidate> out;
  for (std::size_t i = 0; i < count; i++) {
    out.push_back({list[i].entry_id, list[i].title, list[i].user_name, list[i].credential_id});
  }
  tsm_passkeys_free(list, count);
  return out;
}

Signature ClientService::sign(const std::string &url, const std::string &rpId, const std::string &entryId,
                              const Bytes &clientDataHash) {
  if (clientDataHash.size() != 32) throw PluginError(Failure::other, "the client data hash is 32 bytes");
  tsm_passkey_signature *s = nullptr;
  if (tsm_passkey_get(client_, url.c_str(), rpId.c_str(), entryId.c_str(), clientDataHash.data(), &s) != TSM_OK) {
    throw lastClientError();
  }
  Signature out{owned(s->credential_id), owned(s->authenticator_data), owned(s->signature), owned(s->user_handle)};
  tsm_passkey_signature_free(s);
  return out;
}

Created ClientService::create(const CreateRequest &request) {
  std::vector<const char *> exclude;
  for (const auto &e : request.exclude) exclude.push_back(e.c_str());
  tsm_passkey_create_request r;
  std::memset(&r, 0, sizeof r);
  r.url = request.url.c_str();
  r.rp_id = request.rpId.c_str();
  r.user_id = request.userId.data();
  r.user_id_len = request.userId.size();
  r.user_name = request.userName.c_str();
  r.display_name = request.displayName.empty() ? nullptr : request.displayName.c_str();
  r.algorithms = request.algorithms.data();
  r.algorithm_count = request.algorithms.size();
  r.exclude_credentials = exclude.empty() ? nullptr : exclude.data();
  r.exclude_count = exclude.size();
  tsm_passkey_created *made = nullptr;
  if (tsm_passkey_create(client_, &r, &made) != TSM_OK) throw lastClientError();
  Created out{owned(made->credential_id), owned(made->authenticator_data), owned(made->attestation_object),
              owned(made->public_key), made->public_key_algorithm};
  tsm_passkey_created_free(made);
  return out;
}

} // namespace tsm_plugin
