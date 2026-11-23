// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The messages between the extension's parts. Page frames (content scripts)
// and the extension's own pages (the candidate list, the popup) talk to the
// background; only the background talks to the host, and it takes the page's
// address from the browser's sender information, never from what a content
// script or a list claims.

/** A login of the page, as the host answers `match`: never a value. */
export interface Candidate {
  entryId: string;
  title: string;
  userName: string;
  matchedUrl: string;
  hasTotp: boolean;
}

/** A refusal the host or the service answered. */
export interface HostError {
  kind: string;
  message: string;
  reason?: string;
}

/** Where the service stands: `unreachable` when the host does not start. */
export type ServiceState = 'running' | 'locked' | 'not_running' | 'unreachable';

/** The values of one fill, sent to one frame only. */
export interface FillValues {
  userName: string;
  password: string;
  totp?: string;
}

/** Content script → background: open the list for this frame's field. */
export interface OpenListRequest {
  op: 'tsm.openList';
  /** Whether the frame has a one-time-code field (the TOTP is read then). */
  otpField?: boolean;
  /** The field is a new password: the list suggests one instead. */
  newPassword?: boolean;
}

/** Content script → background: a form with a password was submitted
 *  (part-browser, Proposing a login). */
export interface CapturedRequest {
  op: 'tsm.captured';
  userName?: string;
  password: string;
  /** A sign-up or password-change form's new password. */
  change: boolean;
  /** The page's title, the new login's title. */
  title?: string;
}

/** Content script (top frame) → background: a bar waiting for this tab. */
export interface BarPendingRequest {
  op: 'tsm.barPending';
}

/** Bar → background: what it asks about (never the password). */
export interface BarRequest {
  op: 'tsm.bar';
  token: string;
}

/** Bar → background: the user's answer. */
export interface BarAnswerRequest {
  op: 'tsm.barAnswer';
  token: string;
  answer: 'save' | 'notNow' | 'never' | 'close';
}

/** List → background: fill the suggested password into the new-password
 *  fields of the list's frame. */
export interface FillNewRequest {
  op: 'tsm.fillNew';
  token: string;
  password: string;
}

/** Popup → background: proposals for the active tab's site on or off. */
export interface NeverRequest {
  op: 'tsm.never';
  never: boolean;
}

/** What the background answers the bar. */
export interface BarAnswer {
  site: string;
  userName?: string;
  /** `changed`: the vaults hold another password for this login. */
  state: 'new' | 'changed' | 'unknown';
}

/** List → background: what the list it shows holds. */
export interface ListRequest {
  op: 'tsm.list';
  token: string;
  /** Show the frame's own logins (a login form in a frame of another site). */
  frameSite?: boolean;
  /** Wait for the service to be unlocked (the app's unlock comes up). */
  unlock?: boolean;
}

/** List / popup → background: fill a candidate. */
export interface FillRequest {
  op: 'tsm.fill';
  token: string;
  entryId: string;
}

/** List → background: the current TOTP of a candidate, to copy. */
export interface TotpRequest {
  op: 'tsm.totp';
  token: string;
  entryId: string;
}

/** List → background: close it. */
export interface CloseRequest {
  op: 'tsm.close';
  token: string;
}

/** Popup → background: the active tab's state and logins. */
export interface PopupRequest {
  op: 'tsm.popup';
  /** Wait for the service to be unlocked (the app's unlock comes up). */
  unlock?: boolean;
}

/** List / popup → background: open the app (at an entry). */
export interface OpenAppRequest {
  op: 'tsm.openApp';
  entryId?: string;
}

/** Content script → background: a page's passkey sign-in (DP-120). */
export interface PasskeyGetRequest {
  op: 'tsm.passkeyGet';
  options: import('./webauthn').PasskeyGetOptions;
}

/** Content script → background: a page's new passkey. */
export interface PasskeyCreateRequest {
  op: 'tsm.passkeyCreate';
  options: import('./webauthn').PasskeyCreateOptions;
}

/** Background → content script: show the list at the field; fill; close. */
export type ToContent =
  | { op: 'tsm.showList'; token: string; listUrl: string }
  | { op: 'tsm.doFill'; token: string; values: FillValues }
  | { op: 'tsm.closeList'; token: string }
  | { op: 'tsm.openListHere' }
  | { op: 'tsm.doFillNew'; token: string; password: string }
  | { op: 'tsm.showBar'; token: string; barUrl: string }
  | { op: 'tsm.closeBar'; token: string }
  | {
      op: 'tsm.passkeyDone';
      token: string;
      answer: Omit<import('./webauthn').PasskeyBridgeAnswer, '__tsm' | 'id'>;
    };

/** What the background answers the list. */
export interface ListAnswer {
  state: ServiceState;
  candidates: Candidate[];
  /** The page's host, for the list's heading. */
  site: string;
  /** The frame's host when the field is in a frame of another site. */
  crossSite?: string;
  /** A new-password field: the list suggests a password. */
  newPassword?: boolean;
  /** The popup: proposals for this site are off ("Never for this site"). */
  never?: boolean;
  /** A passkey sign-in: the candidates are the page's passkeys. */
  passkey?: boolean;
  error?: HostError;
}

export type ToBackground =
  | OpenListRequest
  | ListRequest
  | FillRequest
  | TotpRequest
  | CloseRequest
  | PopupRequest
  | OpenAppRequest
  | CapturedRequest
  | BarPendingRequest
  | BarRequest
  | BarAnswerRequest
  | FillNewRequest
  | NeverRequest
  | PasskeyGetRequest
  | PasskeyCreateRequest;
