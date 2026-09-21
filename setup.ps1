#Requires -Version 5.1
<#
  NexGen Coding Competition 2026 - Windows setup (engine).

  Scope: C toolchain (gcc + make, via w64devkit), Python 3 + pip (per-user),
  and the Python libraries used in the rounds. Nothing else is installed.

  - Checks what is already present, installs only what is missing.
  - Prefers the local cache folder over the internet.
  - Does not require administrator rights.
  - Writes setup-report.txt next to this script.
  - Safe to run twice.

  Entry point: setup.bat (runs this file with -ExecutionPolicy Bypass).
#>
[CmdletBinding()]
param(
    [string]$Cache = '',
    [string]$Report = '',
    [switch]$Offline
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if (-not $Cache) {
    $localCache = Join-Path $PSScriptRoot 'cache'
    $parentCache = Join-Path (Split-Path -Parent $PSScriptRoot) 'cache'
    if (Test-Path -LiteralPath $localCache) { $Cache = $localCache }
    elseif (Test-Path -LiteralPath $parentCache) { $Cache = $parentCache }
    else { $Cache = $localCache }
}
if (-not $Report) { $Report = Join-Path $PSScriptRoot 'setup-report.txt' }

$script:ReportLines = New-Object 'System.Collections.Generic.List[string]'
$script:HardFails = 0
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$PythonVersion = '3.13.15'
$PythonFile    = "python-$PythonVersion-amd64.exe"
$PythonUrl     = "https://www.python.org/ftp/python/$PythonVersion/$PythonFile"
$W64Version    = '2.10.0'
$W64File       = "w64devkit-x64-$W64Version.7z.exe"
$W64Url        = "https://github.com/skeeto/w64devkit/releases/download/v$W64Version/$W64File"
$W64Sha        = '18d0a4c71a166f8401ab6305781bec5882b40b5e06ba9807c61cb5f3b3c6325e'
$SevenZipFile  = '7zr.exe'
$SevenZipUrl   = 'https://www.7-zip.org/a/7zr.exe'
$PipPackages   = @('Pillow', 'pygame', 'pandas', 'matplotlib', 'requests', 'beautifulsoup4')
$ImportCheck   = 'import importlib.util as u; mods={"PIL":"Pillow","pygame":"pygame","pandas":"pandas","matplotlib":"matplotlib","requests":"requests","bs4":"beautifulsoup4"}; missing=[p for m,p in mods.items() if u.find_spec(m) is None]; print(" ".join(missing))'
$ToolsDir      = Join-Path $env:LOCALAPPDATA 'NexGen\tools'

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'PASS', 'WARN', 'FAIL')][string]$Level = 'INFO')
    $line = "[{0}] {1}" -f $Level, $Message
    $script:ReportLines.Add($line) | Out-Null
    if ($Level -eq 'FAIL') { $script:HardFails++ }
    $color = 'Gray'
    if ($Level -eq 'PASS') { $color = 'Green' }
    elseif ($Level -eq 'WARN') { $color = 'Yellow' }
    elseif ($Level -eq 'FAIL') { $color = 'Red' }
    Write-Host $line -ForegroundColor $color
}

function Save-Report {
    $header = @(
        'NexGen setup report',
        ('Date: ' + (Get-Date).ToString('s')),
        ('OS: ' + [Environment]::OSVersion.VersionString + '   Arch: ' + $env:PROCESSOR_ARCHITECTURE),
        ('Administrator: ' + $script:IsAdmin),
        ''
    )
    try {
        ($header + $script:ReportLines) | Set-Content -LiteralPath $Report -Encoding UTF8
        Write-Host ''
        Write-Host ('Report written to: ' + $Report)
    } catch {
        Write-Host ('Could not write report: ' + $_.Exception.Message) -ForegroundColor Red
    }
}

function Get-CachedAsset {
    param([string]$FileName, [string]$Url, [string]$Sha256, [int]$Retries = 3)
    $target = Join-Path $Cache ("windows\" + $FileName)
    $alt = Join-Path $Cache $FileName
    if (Test-Path -LiteralPath $target) { return $target }
    if (Test-Path -LiteralPath $alt) { return $alt }
    if ($Offline) { return $null }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (Test-Path -LiteralPath $curl) {
                & $curl '-L' '--fail' '--retry' '3' '--retry-delay' '2' '--ssl-no-revoke' '-C' '-' '-o' $target $Url
            } else {
                Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $target
            }
            if (Test-Path -LiteralPath $target) { return $target }
        } catch {
            Write-Log ("Download attempt {0} for {1} failed: {2}" -f $attempt, $FileName, $_.Exception.Message) 'WARN'
        }
        Start-Sleep -Seconds (3 * $attempt)
    }
    return $null
}

function Test-AssetHash {
    param([string]$Path, [string]$Sha256)
    if (-not $Sha256) {
        Write-Log ("No pinned SHA256 for {0}; skipping hash check." -f (Split-Path -Leaf $Path)) 'WARN'
        return $true
    }
    try {
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
        if ($actual -eq $Sha256.ToLower()) {
            Write-Log ("SHA256 OK: {0}" -f (Split-Path -Leaf $Path)) 'PASS'
            return $true
        }
        Write-Log ("SHA256 mismatch for {0}: expected {1}, got {2}" -f (Split-Path -Leaf $Path), $Sha256, $actual) 'FAIL'
    } catch {
        Write-Log ('Hash check failed: ' + $_.Exception.Message) 'FAIL'
    }
    return $false
}

function Test-PythonCandidate {
    param([string]$Exe)
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return $null }
    if ($Exe -match 'WindowsApps') { return $null }
    try {
        $out = (& $Exe --version 2>&1) -join ' '
        if ($LASTEXITCODE -eq 0 -and $out -match 'Python\s+3') { return $out.Trim() }
    } catch { }
    return $null
}

function Get-PythonExe {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('python.exe', 'python3.exe', 'py.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $candidates.Add($cmd.Source) }
    }
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Python\Launcher\py.exe'))
    $base = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    if (Test-Path -LiteralPath $base) {
        Get-ChildItem -LiteralPath $base -Filter 'python.exe' -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $candidates.Add($_.FullName) }
    }
    foreach ($p in @('C:\Python313\python.exe', 'C:\Python312\python.exe', 'C:\Python311\python.exe')) {
        $candidates.Add($p)
    }

    $best = $null; $bestVer = $null; $fallback = $null
    foreach ($p in ($candidates | Select-Object -Unique)) {
        $ver = Test-PythonCandidate -Exe $p
        if (-not $ver) { continue }
        $num = ($ver -replace '^Python\s*', '')
        try { $parsed = [version]$num } catch { $parsed = $null }
        if ($parsed -and $parsed.Major -ge 3 -and $parsed.Minor -ge 8) {
            if (-not $bestVer -or $parsed -gt $bestVer) { $best = $p; $bestVer = $parsed }
        } elseif (-not $fallback) {
            $fallback = $p
        }
    }
    if ($best) { return $best }
    if ($fallback) {
        Write-Log 'Only an old Python 3 was found; libraries may not install cleanly.' 'WARN'
        return $fallback
    }
    return $null
}

function Add-UserPath {
    param([string]$Dir)
    if (-not $Dir) { return }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $parts = @($userPath -split ';' | Where-Object { $_ })
    if ($parts -notcontains $Dir) {
        $newPath = (@($Dir) + $parts) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Log ("Added to user PATH: {0}" -f $Dir) 'PASS'
    }
    if (($env:Path -split ';') -notcontains $Dir) {
        $env:Path = $Dir + ';' + $env:Path
    }
}

function Install-Python {
    Write-Log 'Python 3 not found. Attempting per-user install (no admin needed)...' 'WARN'
    $installer = Get-CachedAsset -FileName $PythonFile -Url $PythonUrl -Sha256 ''
    if (-not $installer) {
        Write-Log 'Python installer unavailable (cache empty and download failed).' 'FAIL'
        return $null
    }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $installer
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
            Write-Log 'Python installer signature is not valid; refusing to run it.' 'FAIL'
            return $null
        }
        Write-Log 'Python installer signature OK (Python Software Foundation).' 'PASS'
    } catch {
        Write-Log ('Signature check failed: ' + $_.Exception.Message) 'FAIL'
        return $null
    }

    $baseArgs = @('/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_pip=1', 'Include_launcher=1',
        'InstallLauncherAllUsers=0', 'AssociateFiles=0', 'Shortcuts=0', 'Include_doc=0',
        'Include_test=0', 'CompileAll=0')
    $proc = Start-Process -FilePath $installer -ArgumentList $baseArgs -Wait -PassThru
    if ($proc.ExitCode -notin @(0, 3010, 1641)) {
        Write-Log ("Installer exit code {0}; retrying without the py launcher." -f $proc.ExitCode) 'WARN'
        $retryArgs = @($baseArgs | Where-Object { $_ -notmatch 'Include_launcher|InstallLauncherAllUsers' })
        $retryArgs += 'Include_launcher=0'
        $proc = Start-Process -FilePath $installer -ArgumentList $retryArgs -Wait -PassThru
    }
    if ($proc.ExitCode -notin @(0, 3010, 1641)) {
        Write-Log ("Python installer failed with exit code {0}." -f $proc.ExitCode) 'FAIL'
        return $null
    }
    Write-Log 'Python installer finished.' 'PASS'

    $exe = Get-PythonExe
    if ($exe) {
        $pyDir = Split-Path -Parent $exe
        if ($pyDir -notmatch 'Launcher') {
            Add-UserPath -Dir $pyDir
            $scripts = Join-Path $pyDir 'Scripts'
            if (Test-Path -LiteralPath $scripts) { Add-UserPath -Dir $scripts }
        }
    }
    return $exe
}

function Install-Mingw {
    Write-Log 'Installing the C toolchain (w64devkit: gcc + make, no admin needed)...'
    $sfx = Get-CachedAsset -FileName $W64File -Url $W64Url -Sha256 $W64Sha
    if (-not $sfx) {
        Write-Log 'w64devkit archive unavailable (cache empty and download failed).' 'FAIL'
        return
    }
    if (-not (Test-AssetHash -Path $sfx -Sha256 $W64Sha)) {
        Write-Log 'Refusing to use a modified w64devkit archive.' 'FAIL'
        return
    }

    $dest = Join-Path $ToolsDir 'w64devkit'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    $gcc = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'gcc.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gcc) {
        $extracted = $false
        try {
            $sfxArgs = @(('-o"{0}"' -f $dest), '-y')
            Start-Process -FilePath $sfx -ArgumentList $sfxArgs -Wait | Out-Null
            $gcc = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'gcc.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($gcc) { $extracted = $true }
        } catch {
            Write-Log ('Direct extraction failed: ' + $_.Exception.Message) 'WARN'
        }
        if (-not $extracted) {
            $seven = Get-CachedAsset -FileName $SevenZipFile -Url $SevenZipUrl -Sha256 ''
            if ($seven) {
                try {
                    & $seven 'x' $sfx ('-o' + $dest) '-y' *> $null
                    $gcc = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'gcc.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
                } catch {
                    Write-Log ('7zr extraction failed: ' + $_.Exception.Message) 'WARN'
                }
            }
        }
        if (-not $gcc) {
            Write-Log 'Could not extract the w64devkit archive.' 'FAIL'
            return
        }
    }

    $binDir = $gcc.DirectoryName
    $makeExe = Join-Path $binDir 'make.exe'
    if (-not (Test-Path -LiteralPath $makeExe)) {
        $altMake = Join-Path $binDir 'mingw32-make.exe'
        if (Test-Path -LiteralPath $altMake) {
            Copy-Item -LiteralPath $altMake -Destination $makeExe -Force
        }
    }
    Add-UserPath -Dir $binDir
    Write-Log ('C toolchain installed at ' + $binDir) 'PASS'
}

function Install-PipPackages {
    param([string]$Exe, [string[]]$Packages)
    $wheels = Join-Path $Cache 'wheels'
    $pipArgs = @('-m', 'pip', 'install', '--user', '--disable-pip-version-check',
        '--no-warn-script-location', '--retries', '10', '--timeout', '60')
    if (Test-Path -LiteralPath $wheels) { $pipArgs += @('--find-links', $wheels) }
    if ($Offline) { $pipArgs += '--no-index' }
    $pipArgs += $Packages
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & $Exe @pipArgs
        if ($LASTEXITCODE -eq 0) {
            Write-Log ('pip install OK: ' + ($Packages -join ', ')) 'PASS'
            return $true
        }
        Write-Log ("pip install attempt {0} failed (exit {1})." -f $attempt, $LASTEXITCODE) 'WARN'
        if ($attempt -eq 1 -and -not $Offline) {
            & $Exe -m pip install --user --upgrade pip *> $null
        }
        Start-Sleep -Seconds (5 * $attempt)
    }
    return $false
}

Write-Log 'NexGen setup starting.'
Write-Log ('Cache folder: ' + $Cache)
if ($Offline) { Write-Log 'Offline mode: only the local cache will be used.' 'WARN' }
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -notin @('AMD64', 'ARM64')) {
    Write-Log ("Unsupported architecture '{0}': the bundled x64 toolchain may not run." -f $arch) 'FAIL'
}
if ($arch -eq 'ARM64') {
    Write-Log 'ARM64 Windows: the x64 toolchain usually runs under emulation, but gcc may be slow.' 'WARN'
}

Write-Log ''
Write-Log '== Python 3 + pip =='
$pythonExe = Get-PythonExe
if ($pythonExe) {
    Write-Log ('Python already present: ' + (Test-PythonCandidate -Exe $pythonExe)) 'PASS'
} else {
    $pythonExe = Install-Python
    if ($pythonExe) { Write-Log ('Python installed: ' + (Test-PythonCandidate -Exe $pythonExe)) 'PASS' }
}

if ($pythonExe) {
    & $pythonExe -m pip --version *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'pip is missing; running ensurepip...' 'WARN'
        & $pythonExe -m ensurepip --user *> $null
        & $pythonExe -m pip --version *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Log 'ensurepip did not help; falling back to get-pip.py...' 'WARN'
            $getPip = Get-CachedAsset -FileName 'get-pip.py' -Url 'https://bootstrap.pypa.io/get-pip.py' -Sha256 ''
            if ($getPip) {
                & $pythonExe $getPip '--user' '--no-warn-script-location' *> $null
            }
        }
    }
    & $pythonExe -m pip --version *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'pip is ready.' 'PASS'
    } else {
        Write-Log 'pip could not be set up; library installs will fail.' 'FAIL'
    }
} else {
    Write-Log 'Python is not available; libraries cannot be installed.' 'FAIL'
}

if ($pythonExe) {
    Write-Log ''
    Write-Log '== Python libraries =='
    $missing = (& $pythonExe -c $ImportCheck 2>$null) -join ' '
    if ($missing -and $missing.Trim()) {
        Write-Log ('Missing libraries: ' + $missing.Trim()) 'WARN'
        Install-PipPackages -Exe $pythonExe -Packages @($missing.Trim() -split '\s+') | Out-Null
        $missing = (& $pythonExe -c $ImportCheck 2>$null) -join ' '
        if ($missing -and $missing.Trim()) {
            Write-Log ('Still missing after pip: ' + $missing.Trim()) 'FAIL'
        } else {
            Write-Log 'All required Python libraries are present.' 'PASS'
        }
    } else {
        Write-Log 'All required Python libraries are present.' 'PASS'
    }
}

Write-Log ''
Write-Log '== C toolchain (gcc + make) =='
$gccCmd = Get-Command gcc.exe -ErrorAction SilentlyContinue
$makeCmd = Get-Command make.exe -ErrorAction SilentlyContinue
if ($gccCmd -and $makeCmd) {
    Write-Log 'gcc and make already present.' 'PASS'
} else {
    Install-Mingw
}

Write-Log ''
Write-Log '== Verification =='
Save-Report
$rc = 1
if ($pythonExe) {
    $verify = Join-Path $PSScriptRoot 'verify.py'
    if (Test-Path -LiteralPath $verify) {
        & $pythonExe $verify $Report
        $rc = $LASTEXITCODE
    } else {
        Write-Log 'verify.py not found next to setup.ps1; deep verification skipped.' 'WARN'
    }
} else {
    Write-Log 'Verification skipped: no Python available.' 'FAIL'
}
if ($rc -eq 0) {
    Write-Host ''
    Write-Host 'Setup OK. You are ready for the competition.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'Setup incomplete. Show setup-report.txt to an invigilator.' -ForegroundColor Red
}
exit $rc
