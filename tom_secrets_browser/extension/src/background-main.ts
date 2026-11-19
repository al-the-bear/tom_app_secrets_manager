// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The background's start (a service worker in Chromium, a background script
// in Firefox).

import { extensionApi } from './api';
import { Background } from './background';

new Background(extensionApi()).install();
