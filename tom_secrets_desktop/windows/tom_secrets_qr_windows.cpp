// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

#include "tom_secrets_qr_windows.h"

#include <d3d11.h>
#include <dxgi.h>
#include <shobjidl_core.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace tom_secrets_desktop {

namespace {

namespace wgc = winrt::Windows::Graphics::Capture;
namespace wgd = winrt::Windows::Graphics::DirectX;

// The messages a capture's picker and frame send to the platform thread.
constexpr UINT kPicked = WM_APP + 0x51;
constexpr UINT kCaptured = WM_APP + 0x52;

flutter::EncodableValue PixelsAnswer(int width, int height,
                                     std::vector<uint8_t> &pixels) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("width")] = flutter::EncodableValue(width);
  map[flutter::EncodableValue("height")] = flutter::EncodableValue(height);
  map[flutter::EncodableValue("order")] = flutter::EncodableValue("bgra");
  map[flutter::EncodableValue("pixels")] = flutter::EncodableValue(pixels);
  SecureZeroMemory(pixels.data(), pixels.size());
  return flutter::EncodableValue(map);
}

// The clipboard's picture: its "PNG" format (browsers, the Snipping Tool),
// else a 24- or 32-bit DIB turned into top-down BGRA, opaque.
flutter::EncodableValue ClipboardImage() {
  if (!OpenClipboard(nullptr)) return flutter::EncodableValue();
  flutter::EncodableValue answer;
  const UINT png = RegisterClipboardFormatW(L"PNG");
  if (png != 0 && IsClipboardFormatAvailable(png)) {
    HANDLE data = GetClipboardData(png);
    const void *bytes = data == nullptr ? nullptr : GlobalLock(data);
    if (bytes != nullptr) {
      const auto *begin = static_cast<const uint8_t *>(bytes);
      std::vector<uint8_t> copy(begin, begin + GlobalSize(data));
      GlobalUnlock(data);
      flutter::EncodableMap map;
      map[flutter::EncodableValue("encoded")] = flutter::EncodableValue(copy);
      SecureZeroMemory(copy.data(), copy.size());
      answer = flutter::EncodableValue(map);
    }
  } else if (IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE data = GetClipboardData(CF_DIB);
    const void *locked = data == nullptr ? nullptr : GlobalLock(data);
    if (locked != nullptr) {
      const auto *header = static_cast<const BITMAPINFOHEADER *>(locked);
      const size_t size = GlobalSize(data);
      const int width = header->biWidth;
      const int height = header->biHeight < 0 ? -header->biHeight
                                              : header->biHeight;
      const bool bottom_up = header->biHeight > 0;
      const int bits = header->biBitCount;
      size_t offset = header->biSize;
      if (header->biCompression == BI_BITFIELDS &&
          header->biSize == sizeof(BITMAPINFOHEADER)) {
        offset += 3 * sizeof(DWORD);
      }
      offset += header->biClrUsed * sizeof(RGBQUAD);
      const size_t stride = ((static_cast<size_t>(width) * bits + 31) / 32) * 4;
      const bool readable =
          width > 0 && height > 0 && (bits == 24 || bits == 32) &&
          (header->biCompression == BI_RGB ||
           header->biCompression == BI_BITFIELDS) &&
          offset + stride * height <= size;
      if (readable) {
        const auto *rows = static_cast<const uint8_t *>(locked) + offset;
        std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
        for (int y = 0; y < height; y++) {
          const uint8_t *row = rows + stride * (bottom_up ? height - 1 - y : y);
          uint8_t *out = pixels.data() + static_cast<size_t>(y) * width * 4;
          for (int x = 0; x < width; x++) {
            const uint8_t *p = row + x * (bits / 8);
            out[x * 4] = p[0];
            out[x * 4 + 1] = p[1];
            out[x * 4 + 2] = p[2];
            // Why: a DIB's fourth byte is mostly 0, which is not
            // transparency; the picture is shown opaque.
            out[x * 4 + 3] = 0xff;
          }
        }
        answer = PixelsAnswer(width, height, pixels);
      }
      GlobalUnlock(data);
    }
  }
  CloseClipboard();
  return answer;
}

}  // namespace

// One capture: the picker, the Direct3D device, the frame pool and the one
// frame copied into memory.
class TomSecretsCapture {
 public:
  TomSecretsCapture(HWND window, std::unique_ptr<flutter::MethodResult<
                                     flutter::EncodableValue>> result)
      : window_(window), result_(std::move(result)) {}

  ~TomSecretsCapture() { Stop(); }

  // Shows the picker; the item picked arrives as kPicked.
  void Pick() {
    wgc::GraphicsCapturePicker picker;
    picker.as<IInitializeWithWindow>()->Initialize(window_);
    picker.PickSingleItemAsync().Completed(
        [window = window_, this](auto const &operation,
                                 winrt::Windows::Foundation::AsyncStatus status) {
          if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
            std::lock_guard<std::mutex> lock(mutex_);
            item_ = operation.GetResults();
          }
          PostMessage(window, kPicked, 0, 0);
        });
  }

  // On kPicked: null when cancelled, else the capture starts and its first
  // frame arrives as kCaptured. Answers false when it is over.
  bool StartCapture() {
    wgc::GraphicsCaptureItem item{nullptr};
    {
      std::lock_guard<std::mutex> lock(mutex_);
      item = item_;
    }
    if (item == nullptr) {
      result_->Success();
      return false;
    }
    try {
      UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
      winrt::check_hresult(D3D11CreateDevice(
          nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, nullptr, 0,
          D3D11_SDK_VERSION, device_.put(), nullptr, context_.put()));
      auto dxgi = device_.as<IDXGIDevice>();
      winrt::com_ptr<::IInspectable> inspectable;
      winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(
          dxgi.get(), inspectable.put()));
      auto device =
          inspectable.as<wgd::Direct3D11::IDirect3DDevice>();
      pool_ = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
          device, wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized, 1,
          item.Size());
      pool_.FrameArrived([this](auto const &pool, auto const &) {
        OnFrame(pool);
      });
      session_ = pool_.CreateCaptureSession(item);
      try {
        session_.IsCursorCaptureEnabled(false);
      } catch (winrt::hresult_error const &) {
        // Before Windows 10 2004 the cursor is captured too.
      }
      session_.StartCapture();
      return true;
    } catch (winrt::hresult_error const &e) {
      result_->Error("capture-failed",
                     "the screen could not be captured: " +
                         winrt::to_string(e.message()));
      return false;
    }
  }

  // Answers the call with [message] when the picker could not open.
  void Fail(const std::string &message) {
    result_->Error("picker-failed", "the screen picker could not open: " + message);
  }

  // On kCaptured: the frame's pixels answered, then cleared.
  void Finish() {
    Stop();
    std::lock_guard<std::mutex> lock(mutex_);
    if (pixels_.empty()) {
      result_->Error("capture-failed", "the screen could not be captured");
      return;
    }
    result_->Success(PixelsAnswer(width_, height_, pixels_));
    pixels_.clear();
  }

 private:
  void OnFrame(wgc::Direct3D11CaptureFramePool const &pool) {
    if (got_frame_.exchange(true)) return;
    auto frame = pool.TryGetNextFrame();
    if (frame != nullptr) {
      try {
        Copy(frame);
      } catch (winrt::hresult_error const &) {
        // Answered as not captured.
      }
    }
    PostMessage(window_, kCaptured, 0, 0);
  }

  void Copy(wgc::Direct3D11CaptureFrame const &frame) {
    auto access = frame.Surface().as<
        ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    winrt::com_ptr<ID3D11Texture2D> texture;
    winrt::check_hresult(access->GetInterface(IID_PPV_ARGS(texture.put())));
    D3D11_TEXTURE2D_DESC desc;
    texture->GetDesc(&desc);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    winrt::com_ptr<ID3D11Texture2D> staging;
    winrt::check_hresult(device_->CreateTexture2D(&desc, nullptr, staging.put()));
    context_->CopyResource(staging.get(), texture.get());
    D3D11_MAPPED_SUBRESOURCE mapped;
    winrt::check_hresult(
        context_->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped));
    const auto size = frame.ContentSize();
    const int width = static_cast<int>(
        (std::min)(static_cast<UINT>(size.Width), desc.Width));
    const int height = static_cast<int>(
        (std::min)(static_cast<UINT>(size.Height), desc.Height));
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
    for (int y = 0; y < height; y++) {
      std::memcpy(pixels.data() + static_cast<size_t>(y) * width * 4,
                  static_cast<const uint8_t *>(mapped.pData) +
                      static_cast<size_t>(y) * mapped.RowPitch,
                  static_cast<size_t>(width) * 4);
    }
    context_->Unmap(staging.get(), 0);
    std::lock_guard<std::mutex> lock(mutex_);
    width_ = width;
    height_ = height;
    pixels_ = std::move(pixels);
  }

  void Stop() {
    if (session_ != nullptr) {
      session_.Close();
      session_ = nullptr;
    }
    if (pool_ != nullptr) {
      pool_.Close();
      pool_ = nullptr;
    }
  }

  HWND window_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result_;
  std::mutex mutex_;
  wgc::GraphicsCaptureItem item_{nullptr};
  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  wgc::Direct3D11CaptureFramePool pool_{nullptr};
  wgc::GraphicsCaptureSession session_{nullptr};
  std::atomic<bool> got_frame_{false};
  int width_ = 0;
  int height_ = 0;
  std::vector<uint8_t> pixels_;
};

TomSecretsQrWindows::TomSecretsQrWindows(
    flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "tom_secrets_desktop/qr",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto &call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
  window_proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
}

TomSecretsQrWindows::~TomSecretsQrWindows() {
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
}

HWND TomSecretsQrWindows::TopLevelWindow() const {
  HWND view = registrar_->GetView() == nullptr
                  ? nullptr
                  : registrar_->GetView()->GetNativeWindow();
  return view == nullptr ? nullptr : GetAncestor(view, GA_ROOT);
}

void TomSecretsQrWindows::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<Result> result) {
  if (method_call.method_name() == "clipboardImage") {
    result->Success(ClipboardImage());
    return;
  }
  if (method_call.method_name() != "captureScreen") {
    result->NotImplemented();
    return;
  }
  if (capture_ != nullptr) {
    result->Error("busy", "a capture is already open");
    return;
  }
  HWND window = TopLevelWindow();
  if (window == nullptr) {
    result->Error("unsupported", "the app has no window to show the picker");
    return;
  }
  try {
    if (!wgc::GraphicsCaptureSession::IsSupported()) {
      result->Error("unsupported",
                    "reading the screen needs Windows 10 1903 or later");
      return;
    }
  } catch (winrt::hresult_error const &e) {
    result->Error("unsupported", winrt::to_string(e.message()));
    return;
  }
  capture_ = std::make_unique<TomSecretsCapture>(window, std::move(result));
  try {
    capture_->Pick();
  } catch (winrt::hresult_error const &e) {
    capture_->Fail(winrt::to_string(e.message()));
    capture_.reset();
  }
}

std::optional<LRESULT> TomSecretsQrWindows::HandleWindowProc(
    HWND /*hwnd*/, UINT message, WPARAM /*wparam*/, LPARAM /*lparam*/) {
  if (capture_ == nullptr) return std::nullopt;
  if (message == kPicked) {
    if (!capture_->StartCapture()) capture_.reset();
    return 0;
  }
  if (message == kCaptured) {
    capture_->Finish();
    capture_.reset();
    return 0;
  }
  return std::nullopt;
}

}  // namespace tom_secrets_desktop
