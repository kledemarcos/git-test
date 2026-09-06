param(
  [Parameter(Mandatory=$true)][string]$SourceRoot
)
$ErrorActionPreference = 'Stop'

function Replace-Exact([string]$Path, [string]$Old, [string]$New) {
  $full = Join-Path $SourceRoot $Path
  $text = [IO.File]::ReadAllText($full)
  if (-not $text.Contains($Old)) { throw "Patch anchor not found in $Path" }
  $text = $text.Replace($Old, $New)
  [IO.File]::WriteAllText($full, $text, [Text.UTF8Encoding]::new($false))
  Write-Host "Patched $Path"
}

# 1) RTX 20/30: keep the architecture detection already present upstream, but
# turn Turing/Ampere from a hard block into an explicit experimental warning.
$oldGpu = @'
  if (gpu->arch == GpuArch::Ada || gpu->arch == GpuArch::Blackwell) {
    r.state = ProbeState::Ok;
    return r;
  }
  r.state = ProbeState::Fail;
  r.remedy = "RTX 40 (Ada) or RTX 50 (Blackwell) is required. Older cards are "
             "refused rather than run badly.";
  return r;
'@
$newGpu = @'
  if (gpu->arch == GpuArch::Ada || gpu->arch == GpuArch::Blackwell) {
    r.state = ProbeState::Ok;
    return r;
  }
  if (gpu->arch == GpuArch::Ampere || gpu->arch == GpuArch::Turing) {
    r.state = ProbeState::Warn;
    r.remedy = "Webparatus experimental mode: RTX 20/30 can start, but they require a user-supplied Turing/Ampere-compatible nvngx_dlssnr.dll. Performance can be very low; passthrough remains available if neural feature creation fails.";
    return r;
  }
  r.state = ProbeState::Fail;
  r.remedy = "An NVIDIA RTX 20, 30, 40 or 50 GPU is required.";
  return r;
'@
Replace-Exact 'src/manager/Probes.cpp' $oldGpu $newGpu

# 2) Windows 10 22H2: WGC CreateForWindow exists there. Treat build 19045 as
# experimental rather than blocking it. Older Windows builds remain blocked.
$oldWin = @'
  r.detail = "Build " + std::to_string(info.dwBuildNumber);
  if (info.dwBuildNumber >= 22000) {
    r.state = ProbeState::Ok;
    return r;
  }
  r.state = ProbeState::Fail;
  r.remedy = "Windows 11 is required: the overlay depends on compositor "
             "behaviour that Windows 10 does not provide.";
  return r;
'@
$newWin = @'
  r.detail = "Build " + std::to_string(info.dwBuildNumber);
  if (info.dwBuildNumber >= 22000) {
    r.state = ProbeState::Ok;
    return r;
  }
  if (info.dwBuildNumber >= 19045) {
    r.state = ProbeState::Warn;
    r.detail += " - Windows 10 22H2 (Webparatus experimental support)";
    r.remedy = "Windows 10 is experimental. Window capture is supported, but newer compositor-only conveniences are disabled.";
    return r;
  }
  r.state = ProbeState::Fail;
  r.remedy = "Windows 10 22H2 build 19045 or Windows 11 is required.";
  return r;
'@
Replace-Exact 'src/manager/Probes.cpp' $oldWin $newWin

# 3) Windows 10 compatibility: IsBorderRequired is newer than the base WGC API.
# Only call it on builds that expose the property. Cursor capture remains disabled.
$oldWgc = @'
  s->impl_->session = s->impl_->pool.CreateCaptureSession(item);
  s->impl_->session.IsCursorCaptureEnabled(false);   // WoW draws its own cursor
  s->impl_->session.IsBorderRequired(false);         // no yellow capture border
  return s;
'@
$newWgc = @'
  s->impl_->session = s->impl_->pool.CreateCaptureSession(item);
  s->impl_->session.IsCursorCaptureEnabled(false);   // WoW draws its own cursor

  // IsBorderRequired is newer than CreateForWindow. Windows 10 22H2 can capture
  // the game, but must not be forced through a property its WGC session may not
  // implement. On newer builds keep the original no-border behaviour.
  RTL_OSVERSIONINFOW os{};
  os.dwOSVersionInfoSize = sizeof(os);
  using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  if (HMODULE ntdll = GetModuleHandleW(L"ntdll.dll")) {
    auto fn = reinterpret_cast<RtlGetVersionFn>(
        reinterpret_cast<void*>(GetProcAddress(ntdll, "RtlGetVersion")));
    if (fn && fn(&os) == 0 && os.dwBuildNumber >= 20348) {
      try { s->impl_->session.IsBorderRequired(false); } catch (...) {}
    }
  }
  return s;
'@
Replace-Exact 'src/common/capture/WgcSource.cpp' $oldWgc $newWgc

# 4) Branding for the Webparatus edition, while retaining upstream licensing.
foreach ($file in @('src/manager/main.cpp','src/runtime/main.cpp')) {
  $full = Join-Path $SourceRoot $file
  $text = [IO.File]::ReadAllText($full)
  $text = $text.Replace('DLSS 5 Sidecar', 'Webparatus DLSS5 Sidecar V3')
  [IO.File]::WriteAllText($full, $text, [Text.UTF8Encoding]::new($false))
  Write-Host "Branded $file"
}

# Add edition identity to the manager's first-run text without removing the
# upstream safety notice.
$manager = Join-Path $SourceRoot 'src/manager/main.cpp'
$text = [IO.File]::ReadAllText($manager)
$anchor = 'constexpr const char* kFirstRunBody ='
if ($text.Contains($anchor)) {
  $text = $text.Replace($anchor, "// Webparatus edition by Klede Marcos Teixeira - YouTube: Webparatus`r`n" + $anchor)
  [IO.File]::WriteAllText($manager, $text, [Text.UTF8Encoding]::new($false))
}

Write-Host 'Webparatus V3 patches applied successfully.' -ForegroundColor Green
