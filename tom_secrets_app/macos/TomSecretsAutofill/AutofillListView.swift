// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import SwiftUI

/// What the provider's list shows.
final class TomSecretsAutofillModel: ObservableObject {
  @Published var snapshot: TomSecretsAutofillSnapshot?
  @Published var matches: [TomSecretsAutofillEntry] = []
  @Published var message: String?
  @Published var query = ""
  /// One-time codes instead of logins (macOS 15).
  @Published var codes = false

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
/// than a day, a search over every login.
struct TomSecretsAutofillListView: View {
  @ObservedObject var model: TomSecretsAutofillModel
  let pick: (TomSecretsAutofillEntry) -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "lock.shield").foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.35))
        Text(model.codes ? "One-time codes" : "Tom Secrets Manager").font(.headline)
        Spacer()
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
      }
      if let message = model.message {
        Text(message).foregroundStyle(.secondary)
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
