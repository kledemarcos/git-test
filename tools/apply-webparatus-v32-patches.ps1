param(
  [Parameter(Mandatory=$true)][string]$SourceRoot
)
$ErrorActionPreference = 'Stop'

# Apply the already-verified V3.1 compatibility patches first.
& (Join-Path $PSScriptRoot 'apply-webparatus-patches.ps1') -SourceRoot $SourceRoot

function Read-Text([string]$Path) {
  [IO.File]::ReadAllText((Join-Path $SourceRoot $Path))
}
function Write-Text([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText((Join-Path $SourceRoot $Path), $Text, [Text.UTF8Encoding]::new($false))
  Write-Host "Patched $Path"
}
function Replace-Regex([string]$Path, [string]$Pattern, [string]$Replacement) {
  $text = Read-Text $Path
  $rx = [regex]::new($Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $rx.IsMatch($text)) { throw "V3.2 patch regex not found in $Path : $Pattern" }
  $text = $rx.Replace($text, $Replacement, 1)
  Write-Text $Path $text
}

# ---------------------------------------------------------------------------
# Windows 10 fullscreen capture fallback
# ---------------------------------------------------------------------------
# WGC window capture can produce black frames on some Windows 10 compositor
# paths when a topmost fullscreen overlay completely covers the target window.
# On Windows 10, capture the monitor that contains WoW instead. The overlay and
# HUD are explicitly excluded from capture below, so the monitor capture sees
# the unobstructed game rather than feeding the sidecar back into itself.
$wgcPattern = '  auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem>\(\)\s*\.as<IGraphicsCaptureItemInterop>\(\);\s*wgc::GraphicsCaptureItem item\{nullptr\};\s*if \(FAILED\(interop->CreateForWindow\(\s*target, winrt::guid_of<wgc::GraphicsCaptureItem>\(\), winrt::put_abi\(item\)\)\)\) \{\s*return nullptr;\s*\}'
$wgcReplacement = @'
  auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem>()
                     .as<IGraphicsCaptureItemInterop>();
  wgc::GraphicsCaptureItem item{nullptr};

  // Webparatus V3.2: on Windows 10 use monitor capture for borderless WoW.
  // This avoids the Win10 occlusion/compositor path that can return black
  // frames when the sidecar overlay fully covers the game window.
  RTL_OSVERSIONINFOW captureOs{};
  captureOs.dwOSVersionInfoSize = sizeof(captureOs);
  using CaptureRtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  bool useMonitorCapture = false;
  if (HMODULE ntdll = GetModuleHandleW(L"ntdll.dll")) {
    auto fn = reinterpret_cast<CaptureRtlGetVersionFn>(
        reinterpret_cast<void*>(GetProcAddress(ntdll, "RtlGetVersion")));
    if (fn && fn(&captureOs) == 0) {
      useMonitorCapture = captureOs.dwBuildNumber >= 19045 && captureOs.dwBuildNumber < 22000;
    }
  }

  HRESULT createHr = E_FAIL;
  if (useMonitorCapture) {
    HMONITOR monitor = MonitorFromWindow(target, MONITOR_DEFAULTTONEAREST);
    if (monitor) {
      createHr = interop->CreateForMonitor(
          monitor, winrt::guid_of<wgc::GraphicsCaptureItem>(), winrt::put_abi(item));
    }
  } else {
    createHr = interop->CreateForWindow(
        target, winrt::guid_of<wgc::GraphicsCaptureItem>(), winrt::put_abi(item));
  }
  if (FAILED(createHr)) return nullptr;
'@
Replace-Regex 'src/common/capture/WgcSource.cpp' $wgcPattern $wgcReplacement

# Exclude the fullscreen DirectComposition overlay from Windows capture.
# WDA_EXCLUDEFROMCAPTURE is supported by the user's Windows 10 22H2 build.
$dcompPath = 'src/common/present/DCompOverlay.cpp'
$dcomp = Read-Text $dcompPath
$dcompAnchor = '  SetLayeredWindowAttributes(o->hwnd_, 0, 255, LWA_ALPHA);'
if (-not $dcomp.Contains($dcompAnchor)) { throw 'DCompOverlay V3.2 anchor not found' }
$dcompInsert = @'
  SetLayeredWindowAttributes(o->hwnd_, 0, 255, LWA_ALPHA);

  // Webparatus V3.2 fullscreen capture: keep this topmost overlay out of the
  // monitor capture stream. Without this, monitor capture would recursively
  // capture the sidecar itself instead of the unobstructed game underneath.
  if (!SetWindowDisplayAffinity(o->hwnd_, static_cast<DWORD>(0x00000011))) {
    DestroyWindow(o->hwnd_);
    o->hwnd_ = nullptr;
    return nullptr;
  }
'@
$dcomp = $dcomp.Replace($dcompAnchor, $dcompInsert.TrimEnd())
Write-Text $dcompPath $dcomp

# Exclude the HUD as well. If Windows cannot exclude it, simply disable the HUD;
# the main overlay can still run safely.
$hudPath = 'src/common/present/Hud.cpp'
$hud = Read-Text $hudPath
$hudAnchor = '  SetLayeredWindowAttributes(h->hwnd_, 0, 210, LWA_ALPHA);'
if (-not $hud.Contains($hudAnchor)) { throw 'HUD V3.2 anchor not found' }
$hudInsert = @'
  SetLayeredWindowAttributes(h->hwnd_, 0, 210, LWA_ALPHA);
  if (!SetWindowDisplayAffinity(h->hwnd_, static_cast<DWORD>(0x00000011))) {
    DestroyWindow(h->hwnd_);
    h->hwnd_ = nullptr;
    return nullptr;
  }
'@
$hud = $hud.Replace($hudAnchor, $hudInsert.TrimEnd())
Write-Text $hudPath $hud

# Make the Windows 10 probe describe the actual V3.2 capture path.
$probePath = 'src/manager/Probes.cpp'
$probe = Read-Text $probePath
$oldRemedy = 'Windows 10 is experimental. Window capture is supported, but newer compositor-only conveniences are disabled.'
$newRemedy = 'Windows 10 is experimental. Webparatus V3.2 uses fullscreen monitor capture with capture-excluded overlay/HUD to avoid the black-frame occlusion path seen with direct window capture.'
if ($probe.Contains($oldRemedy)) {
  $probe = $probe.Replace($oldRemedy, $newRemedy)
  Write-Text $probePath $probe
}

# Version branding.
foreach ($file in @('src/manager/main.cpp','src/runtime/main.cpp')) {
  $text = Read-Text $file
  $text = $text.Replace('Webparatus DLSS5 Sidecar V3', 'Webparatus DLSS5 Sidecar V3.2')
  $text = $text.Replace('Webparatus V3 - Klede Marcos Teixeira', 'Webparatus V3.2 - Klede Marcos Teixeira')
  Write-Text $file $text
}

# Build-time guards: V3.2 must contain the Windows 10 monitor-capture path and
# capture exclusion, otherwise fail rather than shipping another black-screen
# build.
$wgcCheck = Read-Text 'src/common/capture/WgcSource.cpp'
if (-not $wgcCheck.Contains('CreateForMonitor')) { throw 'V3.2 monitor capture path missing.' }
$dcompCheck = Read-Text 'src/common/present/DCompOverlay.cpp'
if (-not $dcompCheck.Contains('0x00000011')) { throw 'V3.2 overlay capture exclusion missing.' }

Write-Host 'Webparatus V3.2 fullscreen capture patches applied successfully.' -ForegroundColor Green
