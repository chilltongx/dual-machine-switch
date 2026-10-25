param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist\windows' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $compiler)) { throw '.NET Framework compiler not found.' }
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
& $compiler /nologo /target:winexe /codepage:65001 /reference:System.Web.Extensions.dll "/out:$OutputDirectory\DisplayOutput.exe" (Join-Path $root 'windows\DisplayOutput.cs')
if ($LASTEXITCODE -ne 0) { throw 'DisplayOutput build failed.' }
& $compiler /nologo /target:winexe /codepage:65001 "/out:$OutputDirectory\SelectiveInputReceiver.exe" (Join-Path $root 'selective-input\WindowsReceiver.cs')
if ($LASTEXITCODE -ne 0) { throw 'SelectiveInputReceiver build failed.' }
Copy-Item (Join-Path $root 'windows\VideoCommand.ps1') $OutputDirectory -Force
Copy-Item (Join-Path $root 'windows\config.example.json') $OutputDirectory -Force
Write-Host "Built Windows components in $OutputDirectory"
