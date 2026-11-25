// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

#ifndef FLUTTER_PLUGIN_TOM_SECRETS_QR_WINDOWS_H_
#define FLUTTER_PLUGIN_TOM_SECRETS_QR_WINDOWS_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>

namespace tom_secrets_desktop {

class TomSecretsCapture;

// `tom_secrets_desktop/qr`: the pictures a TOTP's QR code is read from.
//
// - `clipboardImage`: the clipboard's picture (its "PNG" format, else the
//   DIB) or null;
// - `captureScreen`: the window or display the user picks in
//   Windows.Graphics.Capture's own picker (GraphicsCapturePicker), one
//   frame captured into memory; null when cancelled.
//
// Pixels are answered as `{width, height, pixels, order: "bgra"}`, an image
// file's bytes as `{encoded}`; nothing is written to a file.
class TomSecretsQrWindows {
 public:
  explicit TomSecretsQrWindows(flutter::PluginRegistrarWindows *registrar);
  ~TomSecretsQrWindows();

  TomSecretsQrWindows(const TomSecretsQrWindows &) = delete;
  TomSecretsQrWindows &operator=(const TomSecretsQrWindows &) = delete;

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<Result> result);
  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);
  HWND TopLevelWindow() const;

  flutter::PluginRegistrarWindows *registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  int window_proc_id_ = -1;
  // The capture under way: its picker and frame arrive on other threads and
  // are handed to the platform thread by a message to the top-level window.
  std::unique_ptr<TomSecretsCapture> capture_;
};

}  // namespace tom_secrets_desktop

#endif  // FLUTTER_PLUGIN_TOM_SECRETS_QR_WINDOWS_H_
