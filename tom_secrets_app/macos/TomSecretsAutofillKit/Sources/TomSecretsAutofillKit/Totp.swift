// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import CryptoKit
import Foundation

extension TomSecretsAutofillEntry.Totp {
  /// The code at [date] (RFC 6238 over HMAC-SHA-1, -256 or -512), or nil
  /// for a secret that does not decode.
  public func code(at date: Date = Date()) -> String? {
    guard let key = Data(base64Encoded: secret), period > 0, (1...10).contains(digits) else {
      return nil
    }
    var counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
    let message = Data(bytes: &counter, count: 8)
    let mac: [UInt8]
    let symmetric = SymmetricKey(data: key)
    switch algorithm.uppercased() {
    case "SHA256":
      mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
    case "SHA512":
      mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: symmetric))
    default:
      mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetric))
    }
    let offset = Int(mac[mac.count - 1] & 0x0f)
    let value =
      (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16)
      | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
    var modulus: UInt64 = 1
    for _ in 0..<digits { modulus *= 10 }
    let code = String(UInt64(value) % modulus)
    return String(repeating: "0", count: digits - code.count) + code
  }

  /// Seconds the code at [date] stays valid.
  public func remaining(at date: Date = Date()) -> Int {
    period - Int(date.timeIntervalSince1970) % period
  }
}
