# Manually driven CI for the Tom Secrets Manager - Windows (PowerShell).
#
# Started by a person, from the repository. Nothing schedules it: no
# scheduled task, hook or cloud workflow runs it. From cmd.exe use ci.cmd,
# which starts this script.
#
#   .\ci.ps1 :all        every stage, in order, past any red
#   .\ci.ps1 :test       one stage (several may be named: .\ci.ps1 :analyze :licences)
#   .\ci.ps1 --help      the stages and options
#
# The last line of output is the one summary line; the exit code is non-zero
# when any step is red. Logs: tom_secrets_build\testlog\<timestamp>\.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# The Dart that belongs to the Flutter SDK, so the tool finds that same SDK's
# flutter: FLUTTER_ROOT, then flutter on PATH, then a plain dart on PATH.
$dart = $null
if ($env:FLUTTER_ROOT -and (Test-Path (Join-Path $env:FLUTTER_ROOT 'bin\dart.bat'))) {
    $dart = Join-Path $env:FLUTTER_ROOT 'bin\dart.bat'
}
if (-not $dart) {
    $flutter = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutter) {
        $candidate = Join-Path (Split-Path -Parent $flutter.Source) 'dart.bat'
        if (Test-Path $candidate) { $dart = $candidate }
    }
}
if (-not $dart) {
    $plain = Get-Command dart -ErrorAction SilentlyContinue
    if ($plain) { $dart = $plain.Source }
}
if (-not $dart) {
    [Console]::Error.WriteLine('ci.ps1: no Flutter SDK found - put flutter on PATH or set FLUTTER_ROOT')
    exit 2
}

Push-Location $here
try {
    $config = Join-Path $here '.dart_tool\package_config.json'
    if (-not (Test-Path $config) -or ((Get-Item (Join-Path $here 'pubspec.yaml')).LastWriteTime -gt (Get-Item $config).LastWriteTime)) {
        & $dart pub get
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("ci.ps1: dart pub get failed in $here")
            exit 2
        }
    }
    & $dart run bin/tom_secrets_build.dart @args
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $code
