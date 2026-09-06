param(
  [Parameter(Mandatory=$true)][string]$SourceRoot
)
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'apply-webparatus-v33-dxgi.ps1') -SourceRoot $SourceRoot

function PatchFile([string]$rel, [scriptblock]$transform) {
  $path = Join-Path $SourceRoot $rel
  $text = [IO.File]::ReadAllText($path)
  $text = & $transform $text
  [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

PatchFile 'src/common/capture/WgcSource.cpp' {
  param($t)
  if (-not $t.Contains('#include <string>')) {
    $t = $t.Replace('#include <thread>', "#include <thread>`n#include <string>")
  }
  return $t
}

PatchFile 'src/common/present/DCompOverlay.cpp' {
  param($t)
  if (-not $t.Contains('#include "core/Log.h"')) {
    $replacement = @'
#include "core/Log.h"
#include "gpu/DeviceBridge.h"
'@
    $t = $t.Replace('#include "gpu/DeviceBridge.h"', $replacement.TrimEnd())
  }
  return $t
}

Write-Host 'V3.3 compile wrapper completed.' -ForegroundColor Green
