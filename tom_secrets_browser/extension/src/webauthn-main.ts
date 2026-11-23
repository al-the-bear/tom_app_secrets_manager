// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The page-world script's start, in every frame of every http(s) page
// (the manifest's `world: "MAIN"`, at document start).

import { installPasskeys } from './webauthn-page';

installPasskeys(window);
