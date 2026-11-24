// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause
//
// The passkey service over the C client (tsm::tsm): one connection to the
// service of this user, the passkey requests of protocol.md 5.8, the
// service's refusals as the plugin's failures.
#pragma once

#include "core.h"

struct tsm_client;

namespace tsm_plugin {

class ClientService : public PasskeyService {
public:
  /// A client that connects on its first request.
  ClientService();
  ~ClientService() override;
  ClientService(const ClientService &) = delete;
  ClientService &operator=(const ClientService &) = delete;

  std::vector<Candidate> passkeys(const std::string &url, const std::string &rpId,
                                  const std::vector<std::string> &allow, bool wait) override;
  Signature sign(const std::string &url, const std::string &rpId, const std::string &entryId,
                 const Bytes &clientDataHash) override;
  Created create(const CreateRequest &request) override;

private:
  tsm_client *client_ = nullptr;
};

/// The failure of the C client's last error on this thread.
PluginError lastClientError();

} // namespace tsm_plugin
