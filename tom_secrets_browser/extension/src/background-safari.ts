// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The background's start in Safari: the host is reached through the macOS
// app's handler (safari.ts), not through stdio native messaging.

import { extensionApi, hostName } from './api';
import { Background } from './background';
import { safariPort } from './safari';

const api = extensionApi();
new Background(api, () =>
  safariPort((message) =>
    api.runtime.sendNativeMessage
      ? api.runtime.sendNativeMessage(hostName, message)
      : Promise.reject(new Error('no native messaging here')),
  ),
).install();
