param(
  [Parameter(Mandatory=$true)][string]$SourceRoot
)
$ErrorActionPreference = 'Stop'

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
  if (-not $rx.IsMatch($text)) { throw "Patch regex not found in $Path : $Pattern" }
  $text = $rx.Replace($text, $Replacement, 1)
  Write-Text $Path $text
}

# RTX 20/30: keep upstream architecture detection, but make Turing/Ampere an
# explicit experimental warning rather than a hard block in the manager.
$gpuPattern = '  if \(gpu->arch == GpuArch::Ada \|\| gpu->arch == GpuArch::Blackwell\) \{\s*r\.state = ProbeState::Ok;\s*return r;\s*\}\s*r\.state = ProbeState::Fail;\s*r\.remedy = "RTX 40 \(Ada\) or RTX 50 \(Blackwell\) is required\. Older cards are "\s*"refused rather than run badly\.";\s*return r;'
$gpuReplacement = @'
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
Replace-Regex 'src/manager/Probes.cpp' $gpuPattern $gpuReplacement

# RTX 20/30 runtime startup gate: upstream has a second hard block in
# wowsidecar.exe itself. Allow Turing/Ampere to reach the external pipeline,
# while keeping them explicitly experimental. Unsupported/non-RTX adapters
# remain blocked.
$runtimeGpuPattern = '  if \(gpu->arch != GpuArch::Ada && gpu->arch != GpuArch::Blackwell\) \{\s*GlobalLog\(\)\.Error\(std::string\(ToString\(gpu->arch\)\) \+\s*" is not supported; RTX 40 or RTX 50 required"\);\s*wchar_t msg\[256\];\s*swprintf_s\(msg, L"%hs is not supported\. RTX 40 or RTX 50 required\.",\s*ToString\(gpu->arch\)\);\s*MessageBoxW\(nullptr, msg, L"DLSS 5 Sidecar", MB_ICONERROR\);\s*return 1;\s*\}'
$runtimeGpuReplacement = @'
  const bool supportedArch =
      gpu->arch == GpuArch::Ada || gpu->arch == GpuArch::Blackwell ||
      gpu->arch == GpuArch::Ampere || gpu->arch == GpuArch::Turing;
  if (!supportedArch) {
    GlobalLog().Error(std::string(ToString(gpu->arch)) +
                      " is not supported; NVIDIA RTX 20/30/40/50 required");
    wchar_t msg[256];
    swprintf_s(msg, L"%hs is not supported. NVIDIA RTX 20/30/40/50 required.",
               ToString(gpu->arch));
    MessageBoxW(nullptr, msg, L"DLSS 5 Sidecar", MB_ICONERROR);
    return 1;
  }
  if (gpu->arch == GpuArch::Ampere || gpu->arch == GpuArch::Turing) {
    GlobalLog().Warn(std::string("Webparatus experimental GPU path: ") +
                     ToString(gpu->arch) +
                     "; neural feature creation depends on the user-supplied compatible runtime");
  }
'@
Replace-Regex 'src/runtime/main.cpp' $runtimeGpuPattern $runtimeGpuReplacement

# Windows 10 22H2 build 19045: allow the manager to start in experimental mode.
$winPattern = '  r\.detail = "Build " \+ std::to_string\(info\.dwBuildNumber\);\s*if \(info\.dwBuildNumber >= 22000\) \{\s*r\.state = ProbeState::Ok;\s*return r;\s*\}\s*r\.state = ProbeState::Fail;\s*r\.remedy = "Windows 11 is required: the overlay depends on compositor "\s*"behaviour that Windows 10 does not provide\.";\s*return r;'
$winReplacement = @'
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
Replace-Regex 'src/manager/Probes.cpp' $winPattern $winReplacement

# Windows 10 compatibility: the base WGC capture APIs exist, but
# IsBorderRequired is newer. Only call it when the OS build is new enough.
$wgcPath = 'src/common/capture/WgcSource.cpp'
$wgc = Read-Text $wgcPath
$needle = '  s->impl_->session.IsBorderRequired(false);         // no yellow capture border'
if (-not $wgc.Contains($needle)) { throw "WGC patch anchor not found" }
$guard = @'
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
'@
$wgc = $wgc.Replace($needle, $guard.TrimEnd())
Write-Text $wgcPath $wgc

# Branding for the Webparatus edition. The original MIT licence and third-party
# notices are intentionally left untouched.
foreach ($file in @('src/manager/main.cpp','src/runtime/main.cpp')) {
  $text = Read-Text $file
  $text = $text.Replace('DLSS 5 Sidecar', 'Webparatus DLSS5 Sidecar V3')
  Write-Text $file $text
}

# Add edition identity in a visible first-run title while preserving the full
# upstream safety notice below it.
$managerPath = 'src/manager/main.cpp'
$manager = Read-Text $managerPath
$manager = $manager.Replace('constexpr const char* kFirstRunTitle = "Before you use this";',
  'constexpr const char* kFirstRunTitle = "Webparatus V3 - Klede Marcos Teixeira";')
Write-Text $managerPath $manager

# Regression guard: if the upstream hard block survives, fail the build rather
# than shipping another package that advertises RTX 20/30 but refuses to start.
$runtimeCheck = Read-Text 'src/runtime/main.cpp'
if ($runtimeCheck.Contains('RTX 40 or RTX 50 required')) {
  throw 'RTX 20/30 runtime gate was not removed.'
}

Write-Host 'Webparatus V3 patches applied successfully, including RTX 20/30 runtime gate fix.' -ForegroundColor Green
