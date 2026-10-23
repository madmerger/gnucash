[CmdletBinding()]
param (
    [string]$TargetDir = "",
    [ValidateSet("x86_64", "i686")]
    [string]$Architecture = "x86_64",
    [string]$GnucashRepo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$GnucashBranch = "stable",
    [string]$GowRepo = (Join-Path $HOME "repos\gnucash-on-windows"),
    [switch]$DependenciesOnly,
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($TargetDir)) {
    $TargetDir = if ($Architecture -eq "x86_64") { "C:\gcdev64" } else { "C:\gcdev32" }
}
$IsX64 = $Architecture -eq "x86_64"
$MingwDir = if ($IsX64) { "mingw64" } else { "mingw32" }
$PackageArch = if ($IsX64) { "x86_64" } else { "i686" }
$MingwPackagePrefix = "mingw-w64-$PackageArch-"
$BuildTriplet = if ($IsX64) { "x86_64-w64-mingw32" } else { "i686-w64-mingw32" }
$GuileModule = if ($IsX64) { "guile3" } else { "guile2" }
$SetupScript = Join-Path $GowRepo "setup-mingw64.ps1"
$MsysRoot = Join-Path $TargetDir "msys2"
$MingwPrefix = Join-Path $MsysRoot $MingwDir
$Pacman = Join-Path $MsysRoot "usr\bin\pacman.exe"
$PacmanConfig = Join-Path $MsysRoot "etc\pacman.conf"
$Bsdtar = Join-Path $MsysRoot "usr\bin\bsdtar.exe"
$Cygpath = Join-Path $MsysRoot "usr\bin\cygpath.exe"
$bash = Join-Path $MsysRoot "usr\bin\bash.exe"
$MsysArchiveBase = "https://repo.msys2.org/mingw/$MingwDir/"
$DownloadDir = Join-Path $TargetDir "downloads"
$archiveDependencyDir = Join-Path $DownloadDir "msys2-archive-packages"
if (-not (Test-Path $archiveDependencyDir)) {
    New-Item -ItemType Directory -Path $archiveDependencyDir | Out-Null
}
$WebkitVersion = if ($IsX64) { "2.4.11-999.13" } else { "2.4.11-999.11" }
$WebkitPackage = "$MingwPackagePrefix" + "webkitgtk3-$WebkitVersion-any.pkg.tar.zst"
$LibsoupPackage = "$MingwPackagePrefix" + "libsoup-2.74.3-4-any.pkg.tar.zst"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Invoke-Pacman([string[]]$PacmanArguments) {
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Pacman @PacmanArguments 2>&1 | ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
}

if (-not (Test-Path $SetupScript)) {
    throw "The gnucash-on-windows setup script was not found at $SetupScript"
}

if (-not (Test-Path $MsysRoot)) {
    if ($VerifyOnly) {
        throw "VerifyOnly requires an existing MSYS2 at $MsysRoot"
    }
    if ($IsX64) {
        & $SetupScript -x86_64 -target_dir $TargetDir
    } else {
        & $SetupScript -target_dir $TargetDir
    }
    if ($LASTEXITCODE -ne 0) {
        throw "setup-mingw64.ps1 failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path $Pacman)) {
    throw "MSYS2 pacman was not found at $Pacman"
}

$repoUnixPath = (& $Cygpath -u $GnucashRepo).Trim()
$repoUri = "file://$repoUnixPath"
if ($GnucashBranch -match "['""\\\r\n]") {
    throw "Invalid GnuCash branch name: $GnucashBranch"
}
$gitExe = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$savedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    & $gitExe -C $GnucashRepo check-ref-format --branch $GnucashBranch 2>$null | Out-Null
    $branchCheckExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
if ($branchCheckExitCode -ne 0) {
    throw "Invalid GnuCash branch name: $GnucashBranch"
}
if ($repoUri -match "['""\\\r\n]") {
    throw "Invalid GnuCash repository URI: $repoUri"
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

if ($IsX64) {
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
  <autotools id="guile3" autogen-sh="autoreconf" autogenargs="--disable-jit --disable-lto">
    <branch repo="guile" module="guile-3.0.11.tar.xz" version="3.0.11"
            hash="sha256:818c79d236657a7fa96fb364137cc7b41b3bdee0d65c6174ca03769559579460">
    </branch>
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

}
if (-not $VerifyOnly) {
    [System.IO.File]::WriteAllText($moduleset, $modulesetText, $Utf8NoBom)
}

$index = (Invoke-WebRequest -Uri $MsysArchiveBase -UseBasicParsing).Content
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
    Where-Object { $_.File -match ('^' + [regex]::Escape($MingwPackagePrefix) + 'gcc-15\.2\.0-14-') } |
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
    return "$MsysArchiveBase$($file.File)"
}

function Get-NewestArchivedPackage([string]$Name) {
    $prefix = "$Name-"
    $file = $archives |
        Where-Object { $_.File -match ('^' + [regex]::Escape($prefix) + '\d') } |
        Sort-Object Modified -Descending |
        Select-Object -First 1
    if (-not $file) {
        return $null
    }
    return $file
}

function Get-ArchivedPackagePath([object]$Package) {
    $packagePath = Join-Path $archiveDependencyDir $Package.File
    if (-not (Test-Path $packagePath)) {
        Invoke-WebRequest -Uri "$MsysArchiveBase$($Package.File)" -OutFile $packagePath -UseBasicParsing
    }
    $signaturePath = "$packagePath.sig"
    if (-not (Test-Path $signaturePath)) {
        Invoke-WebRequest -Uri "$MsysArchiveBase$($Package.File).sig" -OutFile $signaturePath -UseBasicParsing
    }
    if ((Get-Item $signaturePath).Length -lt 100) {
        throw "Missing or incomplete MSYS2 signature for $($Package.File)"
    }
    $unixPackagePath = (& $Cygpath -u $packagePath).Trim()
    $unixSignaturePath = (& $Cygpath -u $signaturePath).Trim()
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $bash -lc 'pacman-key --verify "$1" "$2"' verify $unixSignaturePath $unixPackagePath 2>&1 |
            ForEach-Object { Write-Host $_ }
        $signatureExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($signatureExitCode -ne 0) {
        throw "MSYS2 package signature verification failed for $($Package.File)"
    }
    return $packagePath
}

function Get-PackageInfo([string]$Path) {
    $unixPath = (& $Cygpath -u $Path).Trim()
    $packageInfo = & $Bsdtar -xOf $unixPath .PKGINFO
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read .PKGINFO from $Path"
    }
    $metadata = $packageInfo -join "`n"
    return [PSCustomObject]@{
        Dependencies = @(
            [regex]::Matches($metadata, '(?m)^depend = (.+)$') |
                ForEach-Object { $_.Groups[1].Value.Trim() }
        )
        Provides = @(
            [regex]::Matches($metadata, '(?m)^provides = (.+)$') |
                ForEach-Object {
                    ($_.Groups[1].Value -replace '(?:>=|<=|=|>|<).*$','').Trim()
                }
        )
    }
}

function Get-NewestArchivedProvider([string]$Name) {
    $prefix = "$Name-"
    $candidateNames = @(
        foreach ($entry in ($archives | Where-Object { $_.File.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) })) {
            $remainder = $entry.File.Substring($prefix.Length)
            if ($remainder -match '^(.+?)-\d') {
                "$Name-$($Matches[1])"
            }
        }
    ) | Sort-Object -Unique

    foreach ($candidateName in $candidateNames) {
        $candidate = Get-NewestArchivedPackage $candidateName
        if (-not $candidate) {
            continue
        }
        $packagePath = Get-ArchivedPackagePath $candidate
        $metadata = Get-PackageInfo $packagePath
        if ($metadata.Provides -contains $Name) {
            return [PSCustomObject]@{
                Name = $candidateName
                File = $candidate.File
                Path = $packagePath
                Provides = $metadata.Provides
            }
        }
    }
    return $null
}

function Resolve-ArchivedPackageClosure(
    [string[]]$Roots,
    [string[]]$InitialDependencies,
    [string[]]$PinnedPackages,
    [string[]]$DeferredPackages
) {
    $resolved = [ordered]@{}
    $pending = [System.Collections.Queue]::new()
    foreach ($root in $Roots) {
        $pending.Enqueue([PSCustomObject]@{ Name = $root; IsRoot = $true })
    }
    foreach ($dependency in $InitialDependencies) {
        $pending.Enqueue([PSCustomObject]@{ Name = $dependency; IsRoot = $false })
    }

    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        $dependency = $item.Name
        $name = ($dependency -replace '(?:>=|<=|=|>|<).*$','').Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $alreadyResolved = $resolved.Contains($name)
        if (-not $alreadyResolved) {
            $alreadyResolved = @($resolved.Values | Where-Object { $_.Provides -contains $name }).Count -gt 0
        }
        if ($alreadyResolved) {
            continue
        }

        if (-not $item.IsRoot -and $DeferredPackages -contains $name) {
            continue
        }

        if ($PinnedPackages -contains $name) {
            # The pinned archive is installed in the same pacman -U transaction, and pacman rejects any version conflict there.
            continue
        }

        $archive = Get-NewestArchivedPackage $name
        $packageName = $name
        if (-not $archive) {
            $archive = Get-NewestArchivedProvider $name
            if ($archive) {
                $packageName = $archive.Name
            }
        }
        if (-not $archive) {
            if ($item.IsRoot) {
                throw "No archived package for required dependency $name was found"
            }
            $unsatisfied = & $Pacman -T $dependency 2>$null
            if ($LASTEXITCODE -eq 0 -and -not $unsatisfied) {
                continue
            }
            throw "No archived package for unsatisfied dependency $dependency was found"
        }

        $packagePath = if ($archive.Path) { $archive.Path } else { Get-ArchivedPackagePath $archive }
        $metadata = Get-PackageInfo $packagePath
        $resolved[$packageName] = [PSCustomObject]@{
            Name = $packageName
            File = $archive.File
            Path = $packagePath
            Provides = $metadata.Provides
        }
        Write-Host "Resolved $packageName from $($archive.File)"

        foreach ($required in $metadata.Dependencies) {
            $pending.Enqueue([PSCustomObject]@{ Name = $required; IsRoot = $false })
        }
    }

    return @($resolved.Values)
}

$packagesToPin = [System.Collections.Generic.List[string]]::new()
$packageUrls = [System.Collections.Generic.List[string]]::new()
$exactVersions = @{
    "gcc" = "15.2.0-14"
    "gcc-libs" = "15.2.0-14"
    "swig" = "4.2.1-1"
    "glib-networking" = "2.80.1-3"
    "libgcrypt" = "1.12.2-2"
}
$toolchainAndCmakePackages = @(
    "binutils",
    "crt",
    "headers",
    "libwinpthread",
    "winpthreads",
    "cppdap",
    "cmake",
    "ninja",
    "pkgconf",
    "jsoncpp",
    "libarchive",
    "libuv",
    "rhash",
    "zstd",
    "curl",
    "c-ares",
    "ca-certificates",
    "libssh2-wincng",
    "libidn2",
    "libpsl",
    "libunistring",
    "nghttp2",
    "nghttp3",
    "ngtcp2",
    "openssl",
    "brotli",
    "bzip2",
    "expat",
    "libb2",
    "libiconv",
    "libxml2",
    "lz4",
    "pcre2",
    "xz",
    "zlib",
    "glib-networking",
    "glib2",
    "libgcrypt",
    "libgpg-error",
    "sqlite3"
)

$packageComponents = $exactVersions.Keys + $toolchainAndCmakePackages
foreach ($component in ($packageComponents | Sort-Object -Unique)) {
    $name = "$MingwPackagePrefix$component"
    $url = Get-ArchivedPackageUrl $name $exactVersions[$component]
    $file = [System.IO.Path]::GetFileName(([uri]$url).AbsolutePath)
    $packageUrls.Add((Get-ArchivedPackagePath ([PSCustomObject]@{ File = $file })))
    $packagesToPin.Add($name)
}

$splitRuntimeComponents = @(
    "cc-libs",
    "libatomic",
    "libgcc",
    "libgomp",
    "libquadmath",
    "libstdc++"
)
$splitRuntimePackages = @($splitRuntimeComponents | ForEach-Object { "$MingwPackagePrefix$_" })
$installedPackages = & $Pacman -Qq
$installedSplitRuntimePackages = @($splitRuntimePackages | Where-Object { $installedPackages -contains $_ })
if (-not $VerifyOnly -and $installedSplitRuntimePackages.Count -gt 0) {
    $pacmanExitCode = Invoke-Pacman (@("-Rdd", "--noconfirm") + $installedSplitRuntimePackages)
    if ($pacmanExitCode -ne 0) {
        throw "Removing the GCC 16 split runtime packages failed with exit code $pacmanExitCode"
    }
}

if (-not $VerifyOnly) {
    $pacmanExitCode = Invoke-Pacman (@("-U", "--noconfirm", "--needed") + $packageUrls.ToArray())
    if ($pacmanExitCode -ne 0) {
        throw "Installing the archived MinGW toolchain failed with exit code $pacmanExitCode"
    }
}

$webkitPath = Join-Path $DownloadDir $WebkitPackage
$libsoupPath = Join-Path $DownloadDir $LibsoupPackage
if (-not (Test-Path $DownloadDir)) {
    New-Item -ItemType Directory -Path $DownloadDir | Out-Null
}
foreach ($package in @($WebkitPackage, $LibsoupPackage)) {
    $path = Join-Path $DownloadDir $package
    if (-not (Test-Path $path)) {
        Invoke-WebRequest -Uri "https://downloads.sourceforge.net/gnucash/Dependencies/$package" -OutFile $path -UseBasicParsing
    }
}
if ((Get-Item $webkitPath).Length -lt 1000000 -or
    (Get-Item $libsoupPath).Length -lt 1000) {
    throw "The GnuCash WebKitGTK or libsoup package download was incomplete"
}
$sourcePackageHashes = @{
    "mingw-w64-i686-webkitgtk3-2.4.11-999.11-any.pkg.tar.zst" = "365EADE60E5420755EEE6B2DB98C8CB29C1265E175EFCAE04290A7D2FF72B19A"
    "mingw-w64-i686-libsoup-2.74.3-4-any.pkg.tar.zst" = "748AEFEE13458815B025412149703BE8B61D2A0BE0554A558F5D6BDEFEBED75F"
}
foreach ($package in @($WebkitPackage, $LibsoupPackage)) {
    $expectedHash = $sourcePackageHashes[$package]
    if (-not $expectedHash) {
        if ($IsX64) {
            throw "x86_64 SourceForge package hashes are not pinned: $package"
        }
        throw "No pinned SHA256 for SourceForge package $package"
    }
    if ((Get-FileHash (Join-Path $DownloadDir $package) -Algorithm SHA256).Hash -ne $expectedHash) {
        throw "No matching pinned SHA256 for SourceForge package $package"
    }
}

$packagesToPin.Add("$MingwPackagePrefix" + "libsoup")
$packagesToPin.Add("$MingwPackagePrefix" + "webkitgtk3")
foreach ($package in $splitRuntimePackages) {
    $packagesToPin.Add($package)
}

if (-not $IsX64) {
    $archiveDependencyDir = Join-Path $DownloadDir "i686-archive-dependencies"
    if (-not (Test-Path $archiveDependencyDir)) {
        New-Item -ItemType Directory -Path $archiveDependencyDir | Out-Null
    }
    if (-not (Test-Path $Bsdtar) -or -not (Test-Path $Cygpath)) {
        throw "MSYS2 bsdtar and cygpath are required to inspect archived package dependencies"
    }

    $archiveDependencyRoots = @(
        "gtk3",
        "cairo",
        "pango",
        "fontconfig",
        "glib-networking",
        "appstream-glib",
        "boost",
        "libgcrypt",
        "iso-codes",
        "libsecret",
        "docbook-xsl",
        "icu",
        "libmariadbclient",
        "pdcurses",
        "harfbuzz",
        "harfbuzz-icu"
    ) | ForEach-Object { "$MingwPackagePrefix$_" }

    [xml]$moduleSetXml = $modulesetText
    $systemModuleAliases = @{
        "gcrypt" = "libgcrypt"
        "ltdl" = "libltdl"
    }
    $installedPackageNames = & $Pacman -Qq
    foreach ($systemModule in $moduleSetXml.moduleset.systemmodule) {
        if ($systemModule.id -eq "webkitgtk-3.0") {
            continue
        }
        $component = $systemModule.id
        if ($systemModuleAliases.ContainsKey($component)) {
            $component = $systemModuleAliases[$component]
        }
        $packageName = "$MingwPackagePrefix$component"
        if ($installedPackageNames -contains $packageName) {
            continue
        }
        if (-not (Get-NewestArchivedPackage $packageName)) {
            throw "JHBuild system module $($systemModule.id) needs missing package $packageName, which is not in the archive"
        }
        $archiveDependencyRoots += $packageName
    }

    $sourcePackageDependencies = @(
        (Get-PackageInfo $webkitPath).Dependencies
        (Get-PackageInfo $libsoupPath).Dependencies
    )
    $sourcePackageNames = @(
        "$MingwPackagePrefix" + "libsoup"
        "$MingwPackagePrefix" + "webkitgtk3"
    )
    $archiveClosure = Resolve-ArchivedPackageClosure `
        -Roots $archiveDependencyRoots `
        -InitialDependencies $sourcePackageDependencies `
        -PinnedPackages $packagesToPin.ToArray() `
        -DeferredPackages $sourcePackageNames
    $archivePackagePaths = @($archiveClosure | ForEach-Object { $_.Path })
    if (-not $VerifyOnly -and $archivePackagePaths.Count -gt 0) {
        $pacmanExitCode = Invoke-Pacman (@("-U", "--noconfirm", "--needed") + $archivePackagePaths)
        if ($pacmanExitCode -ne 0) {
            throw "Installing the archived i686 dependency closure failed with exit code $pacmanExitCode"
        }
    }
    foreach ($package in $archiveClosure) {
        $packagesToPin.Add($package.Name)
    }
}

if (-not $VerifyOnly) {
    $pacmanExitCode = Invoke-Pacman (@("-U", "--noconfirm", "--needed", $libsoupPath, $webkitPath))
    if ($pacmanExitCode -ne 0) {
        throw "Installing the archived libsoup and GnuCash WebKitGTK packages failed with exit code $pacmanExitCode"
    }
}
if ($VerifyOnly) {
    Write-Host "Verified pinned archives: $($packageUrls -join ', ')"
    if ($archiveClosure) {
        Write-Host "Resolved dependency closure: $(($archiveClosure | ForEach-Object { $_.File }) -join ', ')"
    }
    Write-Host "Verified SourceForge packages: $WebkitPackage, $LibsoupPackage"
    Write-Host "No packages were installed."
    return
}

$config = Get-Content $PacmanConfig -Raw
if ($config -match '(?m)^IgnorePkg\s*=') {
    $existingIgnorePackages = [regex]::Match($config, '(?m)^IgnorePkg\s*=\s*(.*)$').Groups[1].Value -split '\s+'
    $ignorePackages = @($existingIgnorePackages + $packagesToPin | Where-Object { $_ } | Sort-Object -Unique)
    $ignoreLine = "IgnorePkg = " + ($ignorePackages -join " ")
    $config = [regex]::Replace($config, '(?m)^IgnorePkg\s*=.*$', $ignoreLine, 1)
} else {
    $ignoreLine = "IgnorePkg = " + (($packagesToPin | Sort-Object -Unique) -join " ")
    $config = [regex]::Replace($config, '(?m)^\[options\]\s*$', "[options]`r`n$ignoreLine", 1)
}
[System.IO.File]::WriteAllText($PacmanConfig, $config, $Utf8NoBom)

$targetUnixPath = (& $Cygpath -u $TargetDir).Trim()
$jhbuildrc = Join-Path $TargetDir "src\gnucash-on-windows.git\jhbuildrc"
$overrideMarker = "# GnuCash local source override"
$jhbuildConfig = Get-Content $jhbuildrc -Raw
if ($IsX64) {
    $jhbuildConfig = $jhbuildConfig.Replace("'2.2'", "'3.0'")
    $jhbuildConfig = $jhbuildConfig.Replace("module_extra_env['guile2']", "module_extra_env['guile3']")
}
$jhbuildConfig = [regex]::Replace(
    $jhbuildConfig,
    '(?ms)^# GnuCash local source override\r?\n.*?^# End GnuCash local source override\r?\n?',
    ""
)
$buildTripletPattern = '(?m)^    autogenargs = "--build=(?:x86_64|i686)-w64-mingw(?:32|64)"\s*$'
if ($jhbuildConfig -notmatch $buildTripletPattern) {
    throw "The MinGW JHBuild build triplet was not found in $jhbuildrc"
}
$jhbuildConfig = [regex]::Replace(
    $jhbuildConfig,
    $buildTripletPattern,
    "    autogenargs = `"--build=$BuildTriplet`"",
    1
)
$jhbuildConfig += @"

$overrideMarker
os.environ['AR'] = os.path.join(_mingw_base, 'bin', 'ar')
append_autogenargs('libdbi-drivers', '--without-mysql --without-pgsql')
branches['gnucash-git'] = ('$repoUri', '$GnucashBranch')
module_cmakeargs['gnucash-git'] = (
    module_cmakeargs.get('gnucash-git', '') +
    ' -DWITH_SQL=ON -DWITH_AQBANKING=OFF -DWITH_OFX=OFF '
    '-DWITH_PYTHON=OFF -DGNC_DEFAULT_LANG=ja_JP.UTF-8 '
    '-DGTEST_ROOT=`$SRCROOT/googletest-1.16.0'
).strip()
# End GnuCash local source override
"@
[System.IO.File]::WriteAllText($jhbuildrc, $jhbuildConfig, $Utf8NoBom)

$env:TARGET = "gnucash-stable"
$env:MSYSTEM = $MingwDir.ToUpper()
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
        $GuileModule,
        "googletest"
    )
}
$buildCommand = 'cd "$1" && jhbuild -f src/gnucash-on-windows.git/jhbuildrc --no-interact --exit-on-error build --skip=aqbanking,libofx ' + ($buildTargets -join " ")
$savedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    & $bash -lc $buildCommand verify $targetUnixPath
    $buildExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
if ($buildExitCode -ne 0) {
    throw "jhbuild failed with exit code $buildExitCode"
}

if (-not $DependenciesOnly) {
    $gnucashInstallDir = Join-Path $TargetDir "gnucash\stable\inst"
    $msysLocaleDir = Join-Path $MingwPrefix "share\locale"
    $installLocaleDir = Join-Path $gnucashInstallDir "share\locale"
    $iso4217Catalogs = Get-ChildItem -Path $msysLocaleDir -Filter "iso_4217.mo" -Recurse -File
    if (-not $iso4217Catalogs) {
        throw "No iso_4217.mo catalogs were found under $msysLocaleDir"
    }
    foreach ($catalog in $iso4217Catalogs) {
        $relativeCatalogPath = $catalog.FullName.Substring($msysLocaleDir.Length).TrimStart("\", "/")
        $destination = Join-Path $installLocaleDir $relativeCatalogPath
        $destinationDirectory = Split-Path $destination -Parent
        if (-not (Test-Path $destinationDirectory)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }
        Copy-Item -Path $catalog.FullName -Destination $destination -Force
    }
}
