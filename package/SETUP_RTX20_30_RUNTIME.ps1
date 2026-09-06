$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here 'nvngx_dlssnr.dll'
$backup = Join-Path $here 'nvngx_dlssnr.original-package-backup.dll'

$dlg = New-Object System.Windows.Forms.OpenFileDialog
$dlg.Title = 'Selecione o nvngx_dlssnr.dll compatível com RTX 20/30'
$dlg.Filter = 'DLSS Neural Runtime (nvngx_dlssnr.dll)|nvngx_dlssnr.dll|DLL (*.dll)|*.dll|Todos os arquivos (*.*)|*.*'
$dlg.Multiselect = $false

if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
  Write-Host 'Operação cancelada.'
  exit 1
}

$source = $dlg.FileName
if (-not (Test-Path $source)) { throw 'Arquivo selecionado não existe.' }

if ((Test-Path $target) -and -not (Test-Path $backup)) {
  Copy-Item $target $backup -Force
  Write-Host "Backup criado: $backup"
}

Copy-Item $source $target -Force
$hash = (Get-FileHash $target -Algorithm SHA256).Hash
$size = (Get-Item $target).Length

Write-Host ''
Write-Host 'Runtime RTX 20/30 instalado ao lado do Sidecar.' -ForegroundColor Green
Write-Host "Arquivo: $target"
Write-Host "Tamanho: $size bytes"
Write-Host "SHA-256: $hash"
Write-Host ''
Write-Host 'Nenhum arquivo foi copiado para a pasta do World of Warcraft.' -ForegroundColor Cyan
Write-Host 'Agora execute wowsidecar-manager.exe.'
Read-Host 'Pressione ENTER para fechar'
