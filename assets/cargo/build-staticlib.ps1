# CommonsLang_Rust: build one static library from a locked Cargo workspace, offline.
#
# Run by CommonsLang_Rust.Cargo.F_StaticLib on Windows with Windows PowerShell 5.1.
# Every input is a directory that dk materialized; this script never touches the
# network. The arguments are NAME=VALUE pairs, the same as build-staticlib.sh, plus
# vswhere=PATH (the CommonsBase_Build.VSWhere vswhere.exe).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$opt = @{}
foreach ($a in $args) {
  $i = $a.IndexOf('=')
  if ($i -lt 1) { throw "build-staticlib.ps1: argument is not NAME=VALUE: $a" }
  $opt[$a.Substring(0, $i)] = $a.Substring($i + 1)
}
foreach ($k in 'rustver', 'hostslot', 'targetslot', 'host', 'std', 'crates', 'src', 'package', 'lib', 'out', 'vswhere') {
  if (-not $opt.ContainsKey($k) -or [string]::IsNullOrEmpty($opt[$k])) { throw "build-staticlib.ps1: missing $k=" }
}
$features = ''
if ($opt.ContainsKey('features')) { $features = $opt['features'] }
# dk passes the inputs relative to the form's directory; the build changes directory.
foreach ($k in 'host', 'std', 'crates', 'src', 'out') {
  $opt[$k] = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $opt[$k]))
}
# A workspace with no crates.io dependencies has no crates bundle.
if (-not (Test-Path -LiteralPath $opt['crates'])) { New-Item -ItemType Directory -Path $opt['crates'] | Out-Null }

# The slot to Rust target triple table. Keep it equal to the one in Cargo.values.lua
# and build-staticlib.sh. vcvarsall runs on the x64 host for both targets.
$triples = @{
  'Release.Windows_x86_64' = 'x86_64-pc-windows-msvc'
  'Release.Windows_x86'    = 'i686-pc-windows-msvc'
}
$vcarch = @{
  'Release.Windows_x86_64' = 'x64'
  'Release.Windows_x86'    = 'x64_x86'
}
foreach ($s in $opt['hostslot'], $opt['targetslot']) {
  if (-not $triples.ContainsKey($s)) { throw "build-staticlib.ps1: no Rust target for slot $s on this host" }
}
$rustver = $opt['rustver']
$hosttriple = $triples[$opt['hostslot']]
$targettriple = $triples[$opt['targetslot']]
$lib = $opt['lib']

$work = Join-Path ([IO.Path]::GetTempPath()) ('dkrust.' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Path $work | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)

# The lowercase hex sha256 of a file. Get-FileHash lives in the script part of
# Microsoft.PowerShell.Utility, which Windows PowerShell cannot load when dk0 runs
# this script without PSModulePath, so hash with .NET directly.
function Get-Sha256([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($Path)
  try { $bytes = $sha.ComputeHash($stream) } finally { $stream.Dispose(); $sha.Dispose() }
  return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

try {
  # 1. One toolchain tree: rustc, then cargo, then the host and target standard
  #    libraries. rustc finds its sysroot from its own path.
  $tc = Join-Path $work 'toolchain'
  New-Item -ItemType Directory -Path $tc | Out-Null
  Copy-Item -Recurse -Path (Join-Path $opt['host'] "rustc\rustc-$rustver-$hosttriple\rustc\*") -Destination $tc
  Copy-Item -Path (Join-Path $opt['host'] "cargo\cargo-$rustver-$hosttriple\cargo\bin\*") -Destination (Join-Path $tc 'bin')
  $rustlib = Join-Path $tc 'lib\rustlib'
  # The Host object leaves out rustc/lib/rustlib, and Copy-Item -Recurse into a missing
  # folder would rename the copy instead of nesting it.
  New-Item -ItemType Directory -Force -Path $rustlib | Out-Null
  # rustc already made lib\rustlib\<host triple> on Windows, and Copy-Item -Recurse of a folder
  # onto an existing folder fails, so merge the contents of each standard library instead.
  $hostlib = Join-Path $rustlib $hosttriple
  New-Item -ItemType Directory -Force -Path $hostlib | Out-Null
  Copy-Item -Recurse -Force -Path (Join-Path $opt['host'] "std\rust-std-$rustver-$hosttriple\rust-std-$hosttriple\lib\rustlib\$hosttriple\*") -Destination $hostlib
  if ($targettriple -ne $hosttriple) {
    $targetlib = Join-Path $rustlib $targettriple
    New-Item -ItemType Directory -Force -Path $targetlib | Out-Null
    Copy-Item -Recurse -Force -Path (Join-Path $opt['std'] "rust-std-$rustver-$targettriple\rust-std-$targettriple\lib\rustlib\$targettriple\*") -Destination $targetlib
  }

  # 2. The vendored sources, with the .cargo-checksum.json cargo needs for a
  #    directory source. "package" is the sha256 of the .crate.
  $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
  $vendor = Join-Path $work 'vendor'
  New-Item -ItemType Directory -Path $vendor | Out-Null
  foreach ($c in Get-ChildItem -Recurse -File -Path $opt['crates'] -Filter '*.crate') {
    & $tar -xzf $c.FullName -C $vendor
    if ($LASTEXITCODE -ne 0) { throw "tar failed on $($c.Name)" }
    $sum = Get-Sha256 $c.FullName
    $dir = Join-Path $vendor ([IO.Path]::GetFileNameWithoutExtension($c.Name))
    [IO.File]::WriteAllText((Join-Path $dir '.cargo-checksum.json'), "{`"files`":{},`"package`":`"$sum`"}", $utf8)
  }

  # 3. A writable copy of the workspace.
  $ws = Join-Path $work 'src'
  New-Item -ItemType Directory -Path $ws | Out-Null
  Copy-Item -Recurse -Path (Join-Path $opt['src'] '*') -Destination $ws
  Get-ChildItem -Recurse -File $ws | ForEach-Object { $_.IsReadOnly = $false }

  # DkML's OCaml compiles with /MD. Rust's msvc targets default to /MD too; a
  # +crt-static anywhere in the workspace's cargo config would make the archive
  # pull in the static C runtime and clash at the final link.
  foreach ($cfg in Get-ChildItem -Recurse -File -Path $ws -Include 'config', 'config.toml' -ErrorAction SilentlyContinue) {
    if ($cfg.DirectoryName -like '*\.cargo' -and (Select-String -Quiet -SimpleMatch -Pattern 'crt-static' -Path $cfg.FullName)) {
      throw "build-staticlib.ps1: $($cfg.FullName) mentions crt-static; DkML links the /MD C runtime"
    }
  }

  $cargohome = Join-Path $work 'cargo-home'
  New-Item -ItemType Directory -Path $cargohome | Out-Null
  $vendorToml = $vendor.Replace('\', '/')
  [IO.File]::WriteAllText((Join-Path $cargohome 'config.toml'), @"
[source.crates-io]
replace-with = "dk-vendored"

[source.dk-vendored]
directory = "$vendorToml"

[net]
offline = true
"@, $utf8)

  # 4. The MSVC environment, captured from vcvarsall the way dk0's Windows
  #    toolchain contract says: vswhere, then vcvarsall.
  $vsroot = & $opt['vswhere'] -nologo -latest -products * -version '[16.0,19.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($vsroot)) { throw 'build-staticlib.ps1: vswhere found no Visual Studio with the x86.x64 C++ tools' }
  $vcvarsall = Join-Path $vsroot 'VC\Auxiliary\Build\vcvarsall.bat'
  $arch = $vcarch[$opt['targetslot']]
  $lines = & cmd.exe /d /s /c "`"$vcvarsall`" $arch >nul && set"
  if ($LASTEXITCODE -ne 0) { throw "build-staticlib.ps1: vcvarsall $arch failed" }
  foreach ($line in $lines) {
    $i = $line.IndexOf('=')
    if ($i -gt 0) { [Environment]::SetEnvironmentVariable($line.Substring(0, $i), $line.Substring($i + 1), 'Process') }
  }

  foreach ($v in 'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTC_WRAPPER', 'CARGO_BUILD_TARGET') {
    [Environment]::SetEnvironmentVariable($v, $null, 'Process')
  }
  $env:CARGO_HOME = $cargohome
  $env:CARGO_TARGET_DIR = Join-Path $work 'target'
  $env:PATH = (Join-Path $tc 'bin') + ';' + $env:PATH
  $env:RUSTC = Join-Path $tc 'bin\rustc.exe'
  $cargo = Join-Path $tc 'bin\cargo.exe'

  # 5. Build only the static library, and ask rustc for the system libraries.
  $cargoArgs = @('rustc', '--locked', '--offline', '--release', '--target', $targettriple, '-p', $opt['package'], '--crate-type', 'staticlib')
  if ($features -ne '') { $cargoArgs += "--features=$features" }
  $cargoArgs += @('--', '--print', 'native-static-libs')
  $cmdline = 'cargo ' + ($cargoArgs -join ' ')
  $log = Join-Path $work 'cargo.log'
  Push-Location $ws
  try {
    $p = Start-Process -FilePath $cargo -ArgumentList $cargoArgs -NoNewWindow -Wait -PassThru -RedirectStandardError $log -RedirectStandardOutput (Join-Path $work 'cargo.out')
  } finally { Pop-Location }
  Get-Content $log | ForEach-Object { [Console]::Error.WriteLine($_) }
  if ($p.ExitCode -ne 0) { throw "build-staticlib.ps1: cargo exited $($p.ExitCode)" }

  $native = ''
  foreach ($line in Get-Content $log) {
    if ($line.StartsWith('note: native-static-libs: ')) { $native = $line.Substring('note: native-static-libs: '.Length).Trim() }
  }

  # 6. The output object.
  $outlib = Join-Path $opt['out'] 'lib'
  $outshare = Join-Path $opt['out'] 'share'
  New-Item -ItemType Directory -Force -Path $outlib, $outshare | Out-Null
  Copy-Item -Path (Join-Path $env:CARGO_TARGET_DIR "$targettriple\release\$lib.lib") -Destination (Join-Path $outlib "$lib.lib")
  [IO.File]::WriteAllText((Join-Path $outlib 'native-static-libs.txt'), "$native`n", $utf8)
  $words = @()
  foreach ($w in ($native -split '\s+')) { if ($w -ne '') { $words += ('-cclib "' + $w + '"') } }
  [IO.File]::WriteAllText((Join-Path $outlib 'link_flags.sexp'), '(' + ($words -join ' ') + ")`n", $utf8)

  $rustcver = (& $env:RUSTC --version)
  $lockhash = Get-Sha256 (Join-Path $ws 'Cargo.lock')
  $info = [ordered]@{
    rustc             = "$rustcver"
    slot              = $opt['targetslot']
    target            = $targettriple
    host              = $hosttriple
    package           = $opt['package']
    library           = "lib/$lib.lib"
    cargo_lock_sha256 = $lockhash
    cargo_command     = $cmdline
    windows_crt       = '/MD'
  }
  [IO.File]::WriteAllText((Join-Path $outshare 'cargo-build.json'), ((New-Object PSObject -Property $info) | ConvertTo-Json) + "`n", $utf8)
  [Console]::Error.WriteLine("build-staticlib.ps1: wrote $outlib\$lib.lib for $targettriple")
} finally {
  Remove-Item -Recurse -Force -Path $work -ErrorAction SilentlyContinue
}
