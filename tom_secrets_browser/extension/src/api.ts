// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The browser's extension API, as far as the extension uses it, in one shape
// for Chromium (`chrome.*`) and Firefox (`browser.*`): both answer with
// promises in Manifest V3, so no polyfill is needed (webextension-polyfill is
// MPL-2.0, which the product's licence boundary does not take).

/** Where a message came from, as the browser tells it (never the page). */
export interface Sender {
  tab?: { id?: number; url?: string };
  frameId?: number;
  url?: string;
  origin?: string;
  id?: string;
}

/** A native-messaging port. */
export interface NativePort {
  postMessage(message: unknown): void;
  disconnect(): void;
  onMessage: { addListener(listener: (message: unknown) => void): void };
  onDisconnect: { addListener(listener: () => void): void };
}

/** The parts of the API the extension calls. */
export interface ExtensionApi {
  runtime: {
    id: string;
    getURL(path: string): string;
    connectNative(application: string): NativePort;
    sendMessage(message: unknown): Promise<unknown>;
    onMessage: {
      addListener(
        listener: (
          message: unknown,
          sender: Sender,
          sendResponse: (response: unknown) => void,
        ) => boolean | void,
      ): void;
    };
    lastError?: { message?: string };
  };
  tabs: {
    sendMessage(
      tabId: number,
      message: unknown,
      options?: { frameId?: number },
    ): Promise<unknown>;
    query(query: { active: boolean; currentWindow: boolean }): Promise<
      Array<{ id?: number; url?: string }>
    >;
    onRemoved?: { addListener(listener: (tabId: number) => void): void };
  };
  storage?: {
    local: {
      get(key: string): Promise<Record<string, unknown>>;
      set(items: Record<string, unknown>): Promise<void>;
    };
  };
  commands?: {
    onCommand: {
      addListener(listener: (command: string, tab?: { id?: number }) => void): void;
    };
  };
  contextMenus?: {
    create(properties: {
      id: string;
      title: string;
      contexts: string[];
    }): void;
    removeAll(): Promise<void> | void;
    onClicked: {
      addListener(
        listener: (
          info: { menuItemId: string | number; frameId?: number },
          tab?: { id?: number },
        ) => void,
      ): void;
    };
  };
}

declare const browser: ExtensionApi | undefined;
declare const chrome: ExtensionApi | undefined;

/** The browser's API: Firefox's `browser`, else Chromium's `chrome`. */
export function extensionApi(): ExtensionApi {
  if (typeof browser !== 'undefined' && browser) return browser;
  if (typeof chrome !== 'undefined' && chrome) return chrome;
  throw new Error('no extension API here');
}

/** The native-messaging host's name (tom_secrets_client's `tomSecretsBrowserHostId`). */
export const hostName = 'net.tom.secrets';
