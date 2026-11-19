// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The content script's start, in every frame of every http(s) page.

import { extensionApi } from './api';
import { ContentScript } from './content';

new ContentScript(document, extensionApi()).install();
