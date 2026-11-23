// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import SwiftUI

/// A passkey request the provider answers (macOS 14).
enum TomSecretsPasskeyRequest {
  /// A sign-in at `rpId` over `clientDataHash`, with only `allowed`
  /// credential ids when the site names some.
  case assertion(rpId: String, clientDataHash: Data, allowed: [Data])
  /// A new passkey for `rpId` and the user, with the site's algorithms.
  case registration(
    rpId: String, userName: String, userHandle: Data, clientDataHash: Data, algorithms: [Int])
}

/// What the provider's list shows.
final class TomSecretsAutofillModel: ObservableObject {
  @Published var snapshot: TomSecretsAutofillSnapshot?
  @Published var matches: [TomSecretsAutofillEntry] = []
  @Published var message: String?
  @Published var query = ""
  /// One-time codes instead of logins (macOS 15).
  @Published var codes = false
  /// A passkey request instead of logins (macOS 14).
  @Published var passkeyRequest: TomSecretsPasskeyRequest?
  /// The passkeys a sign-in may use (the snapshot's and the pending ones).
  @Published var passkeys: [TomSecretsAutofillPasskey] = []

  /// The entries shown: the matches for the page while the search is
  /// empty, else the search over every login.
  var shown: [TomSecretsAutofillEntry] {
    guard let snapshot else { return [] }
    let pool = codes ? snapshot.entries.filter { $0.totp != nil } : snapshot.entries
    if query.isEmpty {
      let matched = matches.filter { m in pool.contains { $0.id == m.id } }
      return matched.isEmpty ? tomSecretsSearchEntries(pool, query: "") : matched
    }
    return tomSecretsSearchEntries(pool, query: query)
  }
}

/// The provider's interface: a small SwiftUI list (no Flutter engine: the
/// extension's memory is limited), the snapshot's age when it is older
/// than a day, a search over every login; for a passkey request the site's
/// passkeys, or the question whether to make one.
struct TomSecretsAutofillListView: View {
  @ObservedObject var model: TomSecretsAutofillModel
  let pick: (TomSecretsAutofillEntry) -> Void
  let pickPasskey: (TomSecretsAutofillPasskey) -> Void
  let register: () -> Void
  let cancel: () -> Void

  var title: String {
    switch model.passkeyRequest {
    case .assertion: return "Sign in with a passkey"
    case .registration: return "Save a passkey"
    case nil: return model.codes ? "One-time codes" : "Tom Secrets Manager"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "lock.shield").foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.35))
        Text(title).font(.headline)
        Spacer()
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
      }
      if let message = model.message {
        Text(message).foregroundStyle(.secondary)
      } else if case .registration(let rpId, let userName, _, _, _) = model.passkeyRequest {
        Text("Save a passkey for \(userName.isEmpty ? rpId : "\(userName) at \(rpId)") in Tom Secrets Manager?")
        Text("The app puts it into a vault the next time it is unlocked; until then it signs in from this Mac.")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Spacer()
          Button("Save", action: register).keyboardShortcut(.defaultAction)
        }
      } else if case .assertion(let rpId, _, _) = model.passkeyRequest {
        if model.snapshot == nil {
          ProgressView()
        } else if model.passkeys.isEmpty {
          Text("Tom Secrets Manager holds no passkey for \(rpId).").foregroundStyle(.secondary)
        } else {
          List(model.passkeys, id: \.credentialId) { passkey in
            Button {
              pickPasskey(passkey)
            } label: {
              VStack(alignment: .leading) {
                Text(passkey.userName ?? passkey.title ?? passkey.rpId).fontWeight(.semibold)
                Text(passkey.rpId).font(.caption).foregroundStyle(.secondary)
              }
            }
            .buttonStyle(.plain)
          }
          .frame(minHeight: 160)
        }
      } else if let snapshot = model.snapshot {
        if snapshot.isStale() {
          Text("These logins were prepared \(snapshot.ageText()) ago: open Tom Secrets Manager to bring them up to date.")
            .font(.caption).foregroundStyle(.orange)
        }
        TextField("Search all logins", text: $model.query).textFieldStyle(.roundedBorder)
        List(model.shown) { entry in
          Button {
            pick(entry)
          } label: {
            VStack(alignment: .leading) {
              Text(entry.title.isEmpty ? entry.site : entry.title).fontWeight(.semibold)
              Text("\(entry.userName) · \(entry.site)").font(.caption).foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
        }
        .frame(minHeight: 220)
      } else {
        ProgressView()
      }
    }
    .padding(12)
    .frame(minWidth: 380, minHeight: 320)
  }
}
