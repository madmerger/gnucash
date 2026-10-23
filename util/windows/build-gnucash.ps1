[CmdletBinding()]
param (
    [string]$TargetDir = "C:\gcdev64",
    [string]$GnucashRepo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$GnucashBranch = "stable",
    [string]$GowRepo = (Join-Path $HOME "repos\gnucash-on-windows"),
    [switch]$DependenciesOnly
)

$ErrorActionPreference = "Stop"
$SetupScript = Join-Path $GowRepo "setup-mingw64.ps1"
$MsysRoot = Join-Path $TargetDir "msys2"
$MingwPrefix = Join-Path $MsysRoot "mingw64"
$Pacman = Join-Path $MsysRoot "usr\bin\pacman.exe"
$PacmanConfig = Join-Path $MsysRoot "etc\pacman.conf"
$bash = Join-Path $MsysRoot "usr\bin\bash.exe"
$Archive = "https://repo.msys2.org/mingw/mingw64/"
$SourceforgeRepositoryArchive = "https://downloads.sourceforge.net/gnucash/repo/gnc-mingw64-repo.tar.zst"
$DownloadDir = Join-Path $TargetDir "downloads"
$WebkitPackage = "mingw-w64-x86_64-webkitgtk3-2.4.11-999.13-any.pkg.tar.zst"
$LibsoupPackage = "mingw-w64-x86_64-libsoup-2.74.3-4-any.pkg.tar.zst"
$GnuCashRepositoryArchive = Join-Path $DownloadDir "gnc-mingw64-repo.tar.zst"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if (-not (Test-Path $SetupScript)) {
    throw "The gnucash-on-windows setup script was not found at $SetupScript"
}

if (-not (Test-Path $MsysRoot)) {
    & $SetupScript -x86_64 -target_dir $TargetDir
    if ($LASTEXITCODE -ne 0) {
        throw "setup-mingw64.ps1 failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path $Pacman)) {
    throw "MSYS2 pacman was not found at $Pacman"
}

$moduleset = Join-Path $TargetDir "src\gnucash-on-windows.git\gnucash.modules"
if (-not (Test-Path $moduleset)) {
    throw "The GnuCash on Windows moduleset was not found at $moduleset"
}
$modulesetText = [System.IO.File]::ReadAllText($moduleset)
$oldXmlsecHref = 'href="https://www.aleksey.com/xmlsec/download/"'
$newXmlsecHref = 'href="https://www.aleksey.com/xmlsec/download/older-releases/"'
if ($modulesetText.Contains($oldXmlsecHref)) {
    $modulesetText = $modulesetText.Replace($oldXmlsecHref, $newXmlsecHref)
} elseif (-not $modulesetText.Contains($newXmlsecHref)) {
    throw "The xmlsec repository URL was not recognized in $moduleset"
}

$guileRepository = '<repository type="tarball" name="guile" href="https://ftp.gnu.org/gnu/guile/"/>'
if (-not $modulesetText.Contains($guileRepository)) {
    if ($modulesetText.Contains('name="guile"')) {
        throw "The Guile repository URL was not recognized in $moduleset"
    }
    if (-not $modulesetText.Contains("<moduleset>")) {
        throw "The moduleset root was not recognized in $moduleset"
    }
    $modulesetText = $modulesetText.Replace("<moduleset>", "<moduleset>`r`n  $guileRepository")
}

$guileModule = @'
  <autotools id="guile3" autogen-sh="autoreconf" autogenargs="--disable-rpath --enable-networking --enable-nls --enable-posix --enable-regex --without-64-calls --with-threads=no --with-modules --disable-static --disable-jit --disable-lto">
    <branch repo="guile" module="guile-3.0.10.tar.xz" version="3.0.10"
            hash="sha256:bd7168517fd526333446d4f7ab816527925634094fbd37322e17e2b8d8e76388"/>
    <dependencies>
      <dep package="gmp"/>
      <dep package="libffi"/>
      <dep package="bdw-gc"/>
    </dependencies>
  </autotools>
'@
$guileModulePattern = '(?ms)^  <autotools id="guile(?:2|3)"\b.*?^  </autotools>'
if ($modulesetText -notmatch $guileModulePattern) {
    throw "The Guile module definition was not recognized in $moduleset"
}
$modulesetText = [regex]::Replace($modulesetText, $guileModulePattern, $guileModule, 1)
$modulesetText = $modulesetText.Replace('package="guile2"', 'package="guile3"')
if ($modulesetText.Contains('guile2')) {
    throw "The old Guile 2 module remains in $moduleset"
}
[System.IO.File]::WriteAllText($moduleset, $modulesetText, $Utf8NoBom)

$index = (Invoke-WebRequest -Uri $Archive -UseBasicParsing).Content
$archives = foreach ($match in [regex]::Matches(
    $index,
    '(?m)<a href="([^"]+\.pkg\.tar\.zst)">[^<]*</a>\s+(\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2})'
)) {
    [PSCustomObject]@{
        File = [System.IO.Path]::GetFileName($match.Groups[1].Value)
        Modified = [datetime]::ParseExact(
            $match.Groups[2].Value,
            "dd-MMM-yyyy HH:mm",
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
}

$gccArchive = $archives |
    Where-Object { $_.File -match '^mingw-w64-x86_64-gcc-15\.2\.0-14-' } |
    Select-Object -First 1
if (-not $gccArchive) {
    throw "The GCC 15.2.0-14 archive package was not found"
}

function Get-ArchivedPackageUrl([string]$Name, [string]$Version = "") {
    $prefix = "$Name-"
    $candidateArchives = $archives |
        Where-Object {
            $_.File -match ('^' + [regex]::Escape($prefix) + '\d')
        }
    if ($Version) {
        $candidateArchives = $candidateArchives |
            Where-Object { $_.File.StartsWith("$prefix$Version-", [System.StringComparison]::OrdinalIgnoreCase) }
    } else {
        $candidateArchives = $candidateArchives |
            Where-Object { $_.Modified -le $gccArchive.Modified } |
            Sort-Object Modified -Descending
    }
    $file = $candidateArchives | Select-Object -First 1
    if (-not $file) {
        throw "No archived package for $Name was found at the GCC 15.2.0-14 toolchain date"
    }
    return "$Archive$($file.File)"
}

$packagesToPin = [System.Collections.Generic.List[string]]::new()
$packageUrls = [System.Collections.Generic.List[string]]::new()
$exactVersions = @{
    "mingw-w64-x86_64-gcc" = "15.2.0-14"
    "mingw-w64-x86_64-gcc-libs" = "15.2.0-14"
    "mingw-w64-x86_64-swig" = "4.2.1-1"
}
$toolchainAndCmakePackages = @(
    "mingw-w64-x86_64-binutils",
    "mingw-w64-x86_64-crt",
    "mingw-w64-x86_64-headers",
    "mingw-w64-x86_64-libwinpthread",
    "mingw-w64-x86_64-winpthreads",
    "mingw-w64-x86_64-cppdap",
    "mingw-w64-x86_64-cmake",
    "mingw-w64-x86_64-ninja",
    "mingw-w64-x86_64-pkgconf",
    "mingw-w64-x86_64-jsoncpp",
    "mingw-w64-x86_64-libarchive",
    "mingw-w64-x86_64-libuv",
    "mingw-w64-x86_64-rhash",
    "mingw-w64-x86_64-zstd",
    "mingw-w64-x86_64-curl",
    "mingw-w64-x86_64-c-ares",
    "mingw-w64-x86_64-ca-certificates",
    "mingw-w64-x86_64-libssh2-wincng",
    "mingw-w64-x86_64-libidn2",
    "mingw-w64-x86_64-libpsl",
    "mingw-w64-x86_64-libunistring",
    "mingw-w64-x86_64-nghttp2",
    "mingw-w64-x86_64-nghttp3",
    "mingw-w64-x86_64-ngtcp2",
    "mingw-w64-x86_64-openssl",
    "mingw-w64-x86_64-brotli",
    "mingw-w64-x86_64-bzip2",
    "mingw-w64-x86_64-expat",
    "mingw-w64-x86_64-libb2",
    "mingw-w64-x86_64-libiconv",
    "mingw-w64-x86_64-libxml2",
    "mingw-w64-x86_64-lz4",
    "mingw-w64-x86_64-pcre2",
    "mingw-w64-x86_64-xz",
    "mingw-w64-x86_64-zlib",
    "mingw-w64-x86_64-glib-networking",
    "mingw-w64-x86_64-glib2",
    "mingw-w64-x86_64-libgcrypt",
    "mingw-w64-x86_64-libgpg-error",
    "mingw-w64-x86_64-sqlite3"
)

foreach ($name in ($exactVersions.Keys + $toolchainAndCmakePackages | Sort-Object -Unique)) {
    $packageUrls.Add((Get-ArchivedPackageUrl $name $exactVersions[$name]))
    $packagesToPin.Add($name)
}

$splitRuntimePackages = @(
    "mingw-w64-x86_64-cc-libs",
    "mingw-w64-x86_64-libatomic",
    "mingw-w64-x86_64-libgcc",
    "mingw-w64-x86_64-libgomp",
    "mingw-w64-x86_64-libquadmath",
    "mingw-w64-x86_64-libstdc++"
)
$installedPackages = & $Pacman -Qq
$installedSplitRuntimePackages = @($splitRuntimePackages | Where-Object { $installedPackages -contains $_ })
if ($installedSplitRuntimePackages.Count -gt 0) {
    & $Pacman -Rdd --noconfirm $installedSplitRuntimePackages
    if ($LASTEXITCODE -ne 0) {
        throw "Removing the GCC 16 split runtime packages failed with exit code $LASTEXITCODE"
    }
}

& $Pacman -U --noconfirm --needed $packageUrls.ToArray()
if ($LASTEXITCODE -ne 0) {
    throw "Installing the archived MinGW toolchain failed with exit code $LASTEXITCODE"
}

$webkitPath = Join-Path $DownloadDir "mingw64\$WebkitPackage"
$libsoupPath = Join-Path $DownloadDir "mingw64\$LibsoupPackage"
if (-not (Test-Path $DownloadDir)) {
    New-Item -ItemType Directory -Path $DownloadDir | Out-Null
}
if (-not (Test-Path $GnuCashRepositoryArchive)) {
    Invoke-WebRequest -Uri $SourceforgeRepositoryArchive -OutFile $GnuCashRepositoryArchive -UseBasicParsing
}
$repoArchiveUnixPath = (& (Join-Path $MsysRoot "usr\bin\cygpath.exe") -u $GnuCashRepositoryArchive).Trim()
$downloadUnixPath = (& (Join-Path $MsysRoot "usr\bin\cygpath.exe") -u $DownloadDir).Trim()
$extractCommand = "tar --zstd -xf '$repoArchiveUnixPath' -C '$downloadUnixPath' 'mingw64/$WebkitPackage' 'mingw64/$WebkitPackage.sig' 'mingw64/$LibsoupPackage' 'mingw64/$LibsoupPackage.sig'"
& $bash -lc $extractCommand
if ($LASTEXITCODE -ne 0) {
    throw "Extracting WebKitGTK and libsoup from the GnuCash package repository failed with exit code $LASTEXITCODE"
}
if ((Get-Item $GnuCashRepositoryArchive).Length -lt 1000000 -or
    (Get-Item $webkitPath).Length -lt 1000000 -or
    (Get-Item (Join-Path $DownloadDir "mingw64\$WebkitPackage.sig")).Length -lt 100) {
    throw "The GnuCash WebKitGTK repository download or package extraction was incomplete"
}

$packagesToPin.Add("mingw-w64-x86_64-libsoup")
$packagesToPin.Add("mingw-w64-x86_64-webkitgtk3")
foreach ($package in $splitRuntimePackages) {
    $packagesToPin.Add($package)
}
& $Pacman -U --noconfirm --needed $libsoupPath $webkitPath
if ($LASTEXITCODE -ne 0) {
    throw "Installing the archived libsoup and GnuCash WebKitGTK packages failed with exit code $LASTEXITCODE"
}

$ignoreLine = "IgnorePkg = " + (($packagesToPin | Sort-Object -Unique) -join " ")
$config = Get-Content $PacmanConfig -Raw
if ($config -match '(?m)^IgnorePkg\s*=') {
    $config = [regex]::Replace($config, '(?m)^IgnorePkg\s*=.*$', $ignoreLine, 1)
} else {
    $config = [regex]::Replace($config, '(?m)^\[options\]\s*$', "[options]`r`n$ignoreLine", 1)
}
[System.IO.File]::WriteAllText($PacmanConfig, $config, $Utf8NoBom)

$cygpath = Join-Path $MsysRoot "usr\bin\cygpath.exe"
$repoUnixPath = (& $cygpath -u $GnucashRepo).Trim()
$targetUnixPath = (& $cygpath -u $TargetDir).Trim()
$repoUri = "file://$repoUnixPath"
$jhbuildrc = Join-Path $TargetDir "src\gnucash-on-windows.git\jhbuildrc"
$overrideMarker = "# GnuCash local source override"
$jhbuildConfig = Get-Content $jhbuildrc -Raw
$jhbuildConfig = $jhbuildConfig.Replace("'2.2'", "'3.0'")
$jhbuildConfig = $jhbuildConfig.Replace("module_extra_env['guile2']", "module_extra_env['guile3']")
$jhbuildConfig = [regex]::Replace(
    $jhbuildConfig,
    '(?ms)^# GnuCash local source override\r?\n.*?^# End GnuCash local source override\r?\n?',
    ""
)
$buildTripletPattern = '(?m)^    autogenargs = "--build=x86_64-w64-mingw(?:32|64)"\s*$'
if ($jhbuildConfig -notmatch $buildTripletPattern) {
    throw "The x86_64 JHBuild build triplet was not found in $jhbuildrc"
}
$jhbuildConfig = [regex]::Replace(
    $jhbuildConfig,
    $buildTripletPattern,
    '    autogenargs = "--build=x86_64-w64-mingw32"',
    1
)
$jhbuildConfig += @"

$overrideMarker
os.environ['AR'] = os.path.join(_mingw_base, 'bin', 'ar')
append_autogenargs('libdbi-drivers', '--without-mysql --without-pgsql')
branches['gnucash-git'] = ('$repoUri', '$GnucashBranch')
append_autogenargs('gnucash-git', '-DWITH_SQL=ON -DWITH_AQBANKING=OFF -DWITH_OFX=OFF -DWITH_PYTHON=OFF -DGNC_DEFAULT_LANG=ja_JP')
_guile3_cflags = os.environ.get('CFLAGS', '')
module_extra_env['guile3'] = {'CFLAGS': _guile3_cflags + ' -std=gnu11 -Wno-int-conversion -Wno-implicit-function-declaration -Wno-maybe-uninitialized'}
# End GnuCash local source override
"@
[System.IO.File]::WriteAllText($jhbuildrc, $jhbuildConfig, $Utf8NoBom)

$env:TARGET = "gnucash-stable"
$buildTargets = @("gnucash-git")
if ($DependenciesOnly) {
    $buildTargets = @(
        "OpenSP",
        "gwenhywfar",
        "xmlsec",
        "libchipcard",
        "libdbi",
        "pgsql",
        "libdbi-drivers",
        "libatomic-ops",
        "bdw-gc",
        "guile3",
        "googletest"
    )
}
$buildCommand = "cd '$targetUnixPath' && jhbuild -f src/gnucash-on-windows.git/jhbuildrc --no-interact --exit-on-error build --skip=aqbanking,libofx " + ($buildTargets -join " ")
& $bash -lc $buildCommand
if ($LASTEXITCODE -ne 0) {
    throw "jhbuild failed with exit code $LASTEXITCODE"
}
