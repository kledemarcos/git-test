param(
  [Parameter(Mandatory=$true)][string]$SourceRoot
)
$ErrorActionPreference = 'Stop'

# Start from the verified RTX20/30 + Windows 10 compatibility patch set.
& (Join-Path $PSScriptRoot 'apply-webparatus-patches.ps1') -SourceRoot $SourceRoot

function Read-Text([string]$Path) {
  [IO.File]::ReadAllText((Join-Path $SourceRoot $Path))
}
function Write-Text([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText((Join-Path $SourceRoot $Path), $Text, [Text.UTF8Encoding]::new($false))
  Write-Host "Patched $Path"
}

# ---------------------------------------------------------------------------
# V3.3: TRUE DXGI Desktop Duplication on Windows 10 22H2.
# ---------------------------------------------------------------------------
# V3.2 still used Windows.Graphics.Capture CreateForMonitor. That did not fix
# the user's black frame on Windows 10. V3.3 replaces the Win10 capture path
# with IDXGIOutput1::DuplicateOutput, while keeping WGC window capture on Win11.
$wgcSource = @'
#include "capture/WgcSource.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <d3d11_4.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <atomic>
#include <chrono>
#include <thread>

#include "core/Log.h"
#include "gpu/DeviceBridge.h"

using Microsoft::WRL::ComPtr;
namespace wgc = winrt::Windows::Graphics::Capture;
namespace wgdx = winrt::Windows::Graphics::DirectX;

namespace sidecar {

struct WgcSource::Impl {
  // Windows 11 WGC path.
  wgc::GraphicsCaptureItem item{nullptr};
  wgc::Direct3D11CaptureFramePool pool{nullptr};
  wgc::GraphicsCaptureSession session{nullptr};
  winrt::event_token frameToken{};
  winrt::event_token closedToken{};

  // Windows 10 V3.3 DXGI Desktop Duplication path.
  bool useDesktopDuplication = false;
  ComPtr<IDXGIOutputDuplication> duplication;
  std::thread duplicationThread;
  std::atomic<bool> stopDuplication{false};

  DeviceBridge* bridge = nullptr;
  WgcSource::DropCallback onDrop;
  WgcSource* owner = nullptr;
};

namespace {

wgdx::Direct3D11::IDirect3DDevice WrapDevice(ID3D11Device* dev) {
  ComPtr<IDXGIDevice> dxgi;
  if (FAILED(dev->QueryInterface(IID_PPV_ARGS(&dxgi)))) return nullptr;
  winrt::com_ptr<::IInspectable> inspectable;
  if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(), inspectable.put()))) return nullptr;
  return inspectable.as<wgdx::Direct3D11::IDirect3DDevice>();
}

ComPtr<ID3D11Texture2D> SurfaceToTexture(
    const wgdx::Direct3D11::IDirect3DSurface& surface) {
  auto access = surface.as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
  ComPtr<ID3D11Texture2D> tex;
  access->GetInterface(IID_PPV_ARGS(&tex));
  return tex;
}

bool UseWin10DesktopDuplication() {
  RTL_OSVERSIONINFOW os{};
  os.dwOSVersionInfoSize = sizeof(os);
  using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  if (HMODULE ntdll = GetModuleHandleW(L"ntdll.dll")) {
    auto fn = reinterpret_cast<RtlGetVersionFn>(
        reinterpret_cast<void*>(GetProcAddress(ntdll, "RtlGetVersion")));
    if (fn && fn(&os) == 0) {
      return os.dwBuildNumber >= 19045 && os.dwBuildNumber < 22000;
    }
  }
  return false;
}

ComPtr<IDXGIOutputDuplication> CreateDuplicationForTarget(HWND target,
                                                          ID3D11Device* device) {
  const HMONITOR wanted = MonitorFromWindow(target, MONITOR_DEFAULTTONEAREST);
  if (!wanted) return nullptr;

  ComPtr<IDXGIDevice> dxgiDevice;
  if (FAILED(device->QueryInterface(IID_PPV_ARGS(&dxgiDevice)))) return nullptr;
  ComPtr<IDXGIAdapter> adapter;
  if (FAILED(dxgiDevice->GetAdapter(&adapter))) return nullptr;

  for (UINT i = 0;; ++i) {
    ComPtr<IDXGIOutput> output;
    const HRESULT enumHr = adapter->EnumOutputs(i, &output);
    if (enumHr == DXGI_ERROR_NOT_FOUND) break;
    if (FAILED(enumHr)) return nullptr;

    DXGI_OUTPUT_DESC desc{};
    if (FAILED(output->GetDesc(&desc)) || desc.Monitor != wanted) continue;

    ComPtr<IDXGIOutput1> output1;
    if (FAILED(output.As(&output1))) return nullptr;

    ComPtr<IDXGIOutputDuplication> duplication;
    const HRESULT hr = output1->DuplicateOutput(device, &duplication);
    if (FAILED(hr)) {
      GlobalLog().Error("Webparatus V3.3: IDXGIOutput1::DuplicateOutput failed: " +
                        std::to_string(static_cast<unsigned long>(hr)));
      return nullptr;
    }
    return duplication;
  }
  return nullptr;
}

}  // namespace

std::unique_ptr<WgcSource> WgcSource::CreateForWindow(HWND target,
                                                      DeviceBridge& bridge,
                                                      DropCallback onDrop) {
  std::unique_ptr<WgcSource> s(new WgcSource());
  s->target_ = target;
  s->impl_ = std::make_unique<Impl>();
  s->impl_->owner = s.get();
  s->impl_->bridge = &bridge;
  s->impl_->onDrop = std::move(onDrop);

  if (UseWin10DesktopDuplication()) {
    s->impl_->duplication = CreateDuplicationForTarget(target, bridge.D3d11());
    if (!s->impl_->duplication) return nullptr;
    s->impl_->useDesktopDuplication = true;
    GlobalLog().Info("capture backend: Webparatus V3.3 DXGI Desktop Duplication (Windows 10)");
    return s;
  }

  // Windows 11 keeps the upstream WGC window path.
  if (!wgc::GraphicsCaptureSession::IsSupported()) return nullptr;
  auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem>()
                     .as<IGraphicsCaptureItemInterop>();
  wgc::GraphicsCaptureItem item{nullptr};
  if (FAILED(interop->CreateForWindow(
          target, winrt::guid_of<wgc::GraphicsCaptureItem>(), winrt::put_abi(item)))) {
    return nullptr;
  }

  auto device = WrapDevice(bridge.D3d11());
  if (!device) return nullptr;

  s->impl_->item = item;
  s->impl_->pool = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
      device, wgdx::DirectXPixelFormat::B8G8R8A8UIntNormalized,
      static_cast<int32_t>(DeviceBridge::kRingDepth), item.Size());

  Impl* impl = s->impl_.get();
  impl->frameToken = impl->pool.FrameArrived(
      [impl](const wgc::Direct3D11CaptureFramePool& pool, auto&&) {
        auto frame = pool.TryGetNextFrame();
        if (!frame) return;
        auto tex = SurfaceToTexture(frame.Surface());
        if (!tex) return;
        const bool dropped = impl->bridge->Publish(tex.Get());
        impl->owner->delivered_.fetch_add(1, std::memory_order_relaxed);
        if (dropped && impl->onDrop) impl->onDrop();
      });

  impl->closedToken = item.Closed([impl](auto&&, auto&&) {
    impl->owner->closed_.store(true, std::memory_order_release);
  });

  s->impl_->session = s->impl_->pool.CreateCaptureSession(item);
  s->impl_->session.IsCursorCaptureEnabled(false);
  try { s->impl_->session.IsBorderRequired(false); } catch (...) {}
  GlobalLog().Info("capture backend: Windows Graphics Capture window (Windows 11)");
  return s;
}

WgcSource::~WgcSource() { Stop(); }

bool WgcSource::IsClosed() const {
  if (closed_.load(std::memory_order_acquire)) return true;
  return target_ != nullptr && !IsWindow(target_);
}

void WgcSource::Start() {
  if (!impl_) return;

  if (impl_->useDesktopDuplication) {
    if (impl_->duplicationThread.joinable()) return;
    impl_->stopDuplication.store(false, std::memory_order_release);
    Impl* impl = impl_.get();
    impl_->duplicationThread = std::thread([impl] {
      const HRESULT coHr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      bool sizeMismatchReported = false;
      while (!impl->stopDuplication.load(std::memory_order_acquire)) {
        DXGI_OUTDUPL_FRAME_INFO frameInfo{};
        ComPtr<IDXGIResource> resource;
        HRESULT hr = impl->duplication->AcquireNextFrame(100, &frameInfo, &resource);
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) continue;
        if (hr == DXGI_ERROR_ACCESS_LOST) {
          GlobalLog().Error("Webparatus V3.3: desktop duplication access lost");
          impl->owner->closed_.store(true, std::memory_order_release);
          break;
        }
        if (FAILED(hr)) {
          GlobalLog().Error("Webparatus V3.3: AcquireNextFrame failed: " +
                            std::to_string(static_cast<unsigned long>(hr)));
          impl->owner->closed_.store(true, std::memory_order_release);
          break;
        }

        ComPtr<ID3D11Texture2D> tex;
        const HRESULT texHr = resource.As(&tex);
        if (SUCCEEDED(texHr) && tex) {
          D3D11_TEXTURE2D_DESC desc{};
          tex->GetDesc(&desc);
          if (desc.Width == impl->bridge->Width() &&
              desc.Height == impl->bridge->Height() &&
              desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM) {
            const bool dropped = impl->bridge->Publish(tex.Get());
            impl->owner->delivered_.fetch_add(1, std::memory_order_relaxed);
            if (dropped && impl->onDrop) impl->onDrop();
          } else if (!sizeMismatchReported) {
            sizeMismatchReported = true;
            GlobalLog().Error("Webparatus V3.3: duplicated monitor frame does not match the WoW/bridge size or BGRA8 format");
          }
        }

        impl->duplication->ReleaseFrame();
      }
      if (SUCCEEDED(coHr)) CoUninitialize();
    });
    return;
  }

  if (impl_->session) impl_->session.StartCapture();
}

void WgcSource::Stop() {
  if (!impl_) return;

  if (impl_->useDesktopDuplication) {
    impl_->stopDuplication.store(true, std::memory_order_release);
    if (impl_->duplicationThread.joinable()) impl_->duplicationThread.join();
    impl_->duplication.Reset();
    return;
  }

  if (impl_->pool && impl_->frameToken) {
    impl_->pool.FrameArrived(impl_->frameToken);
    impl_->frameToken = {};
  }
  if (impl_->item && impl_->closedToken) {
    impl_->item.Closed(impl_->closedToken);
    impl_->closedToken = {};
  }
  if (impl_->session) { impl_->session.Close(); impl_->session = nullptr; }
  if (impl_->pool) { impl_->pool.Close(); impl_->pool = nullptr; }
}

}  // namespace sidecar
'@
Write-Text 'src/common/capture/WgcSource.cpp' $wgcSource

# Exclude the presentation windows from OS capture. This keeps the DXGI desktop
# duplication source from recursively seeing the sidecar overlay/HUD.
$dcompPath = 'src/common/present/DCompOverlay.cpp'
$dcomp = Read-Text $dcompPath
$dcompAnchor = '  SetLayeredWindowAttributes(o->hwnd_, 0, 255, LWA_ALPHA);'
if (-not $dcomp.Contains($dcompAnchor)) { throw 'DCompOverlay V3.3 anchor not found' }
$dcompInsert = @'
  SetLayeredWindowAttributes(o->hwnd_, 0, 255, LWA_ALPHA);
  if (!SetWindowDisplayAffinity(o->hwnd_, static_cast<DWORD>(0x00000011))) {
    GlobalLog().Warn("Webparatus V3.3: overlay capture exclusion was unavailable; continuing without it");
  }
'@
$dcomp = $dcomp.Replace($dcompAnchor, $dcompInsert.TrimEnd())
Write-Text $dcompPath $dcomp

$hudPath = 'src/common/present/Hud.cpp'
$hud = Read-Text $hudPath
$hudAnchor = '  SetLayeredWindowAttributes(h->hwnd_, 0, 210, LWA_ALPHA);'
if (-not $hud.Contains($hudAnchor)) { throw 'HUD V3.3 anchor not found' }
$hudInsert = @'
  SetLayeredWindowAttributes(h->hwnd_, 0, 210, LWA_ALPHA);
  SetWindowDisplayAffinity(h->hwnd_, static_cast<DWORD>(0x00000011));
'@
$hud = $hud.Replace($hudAnchor, $hudInsert.TrimEnd())
Write-Text $hudPath $hud

# Manager text now states the actual backend used on Windows 10.
$probePath = 'src/manager/Probes.cpp'
$probe = Read-Text $probePath
$probe = $probe.Replace(
  'Windows 10 is experimental. Window capture is supported, but newer compositor-only conveniences are disabled.',
  'Windows 10 is experimental. Webparatus V3.3 uses true DXGI Desktop Duplication (IDXGIOutput1::DuplicateOutput) for fullscreen/borderless capture; Windows 11 keeps WGC window capture.')
Write-Text $probePath $probe

# Branding.
foreach ($file in @('src/manager/main.cpp','src/runtime/main.cpp')) {
  $text = Read-Text $file
  $text = $text.Replace('Webparatus DLSS5 Sidecar V3', 'Webparatus DLSS5 Sidecar V3.3')
  $text = $text.Replace('Webparatus V3 - Klede Marcos Teixeira', 'Webparatus V3.3 - Klede Marcos Teixeira')
  Write-Text $file $text
}

# Build-time guards. Fail rather than ship another WGC-monitor build by mistake.
$verify = Read-Text 'src/common/capture/WgcSource.cpp'
if (-not $verify.Contains('DuplicateOutput(device')) { throw 'V3.3 true DXGI DuplicateOutput backend missing.' }
if ($verify.Contains('CreateForMonitor')) { throw 'V3.3 must not use WGC CreateForMonitor on Windows 10.' }
if (-not $verify.Contains('capture backend: Webparatus V3.3 DXGI Desktop Duplication')) { throw 'V3.3 runtime backend marker missing.' }

Write-Host 'Webparatus V3.3 true DXGI Desktop Duplication patches applied successfully.' -ForegroundColor Green
