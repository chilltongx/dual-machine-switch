$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'MonitorSwitch'
$request = Get-Content (Join-Path $root 'video-request.json') -Raw | ConvertFrom-Json
$requestGuid = [Guid]::Empty
if (-not [Guid]::TryParse([string]$request.id, [ref]$requestGuid)) { throw 'Invalid request ID' }
if ($request.action -notin @('detach', 'restore', 'inspect')) { throw 'Invalid video action' }
$result = @{ id = [string]$request.id; action = [string]$request.action; success = $false }
try {
    $process = Start-Process -FilePath (Join-Path $root 'DisplayOutput.exe') -ArgumentList ('/' + $request.action) -Wait -PassThru
    $result.exitCode = $process.ExitCode
    $result.success = ($process.ExitCode -eq 0)
    if ($result.success) { $result.state = Get-Content (Join-Path $root 'display-output-state.json') -Raw | ConvertFrom-Json }
    else { $result.error = 'Display output change failed; inspect output.log.' }
} catch {
    $result.error = $_.Exception.Message
} finally {
    $temporary = Join-Path $root ('video-result-' + $requestGuid.ToString() + '.tmp')
    $result | ConvertTo-Json -Depth 5 | Set-Content $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination (Join-Path $root 'video-result.json') -Force
}
if (-not $result.success) { exit 1 }
