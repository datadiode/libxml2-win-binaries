<#
This script builds libiconv,libxml2 and libxslt
#>
Param(
    [switch]$x64,
    [switch]$arm64,
    [switch]$vs2008
)

$ErrorActionPreference = "Stop"
Import-Module Pscx

$platDir = If($x64) { "\x64" } ElseIf ($arm64) { "\arm64" } Else { "" }
$distname = If($x64) { "win64" } ElseIf($arm64) { "win-arm64" } Else { "win32" }
If($vs2008) {
    $distname = "vs2008.$distname"
} else {
    if ($platDir -eq "") { $platDir = "\Win32" }
}

If($vs2008) {
    $vcvarsarch = If($x64) { "amd64" } Else { "x86" }
    Import-VisualStudioVars -VisualStudioVersion "90" -Architecture $vcvarsarch
} Else {
    $vcvarsarch = If($x64) { "x86_amd64" } ElseIf ($arm64) { "x86_arm64" } Else { "32" }
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    $env:VisualStudioInstallationPath = & $vswhere '--%' -latest -property installationPath
    cmd.exe /c "call `"%VisualStudioInstallationPath%\VC\Auxiliary\Build\vcvars$vcvarsarch.bat`" && set > %temp%\vcvars$vcvarsarch.txt"
    Get-Content "$env:temp\vcvars$vcvarsarch.txt" | Foreach-Object {
        if ($_ -match "^(.*?)=(.*)$") {
            Set-Content "env:\$($matches[1])" $matches[2]
        }
    }
}

Set-Location $PSScriptRoot

if($vs2008) {
    Set-Location .\libiconv\MSVC9
    $vcarch = If($x64) { "x64" } Else {"Win32"}
    vcbuild libiconv_static\libiconv_static.vcproj "Release|$vcarch"
    $iconvLib = Join-Path (pwd) libiconv_static$platDir\Release
} else {
    Set-Location .\libiconv\MSVC16\
    msbuild libiconv_static\libiconv_static.vcxproj /p:Configuration=Release
    $iconvLib = Join-Path (pwd) $platDir\lib
}

# lxml expects iconv to be called libiconv, not libiconv_a
Dir $iconvLib\libiconv_a* | Copy-Item -Force -Destination {Join-Path $iconvLib ($_.Name -replace "libiconv_a","libiconv") }

$iconvInc = Join-Path $PSScriptRoot libiconv\source\include

Set-Location $PSScriptRoot

Set-Location .\zlib
cmd /c "nmake -f win32/Makefile.msc zlib_a.lib 2>&1"
$zlibLib = (pwd)
$zlibInc = (pwd)

# lxml expects zlib to be called zlib, not zlib_a
Dir $zlibLib\zlib_a* | Copy-Item -Force -Destination {Join-Path $zlibLib ($_.Name -replace "zlib_a","zlib") }

Set-Location ..

Set-Location .\libxml2\win32
cscript configure.js lib="$zlibLib;$iconvLib" include="$zlibInc;$iconvInc" vcmanifest=yes zlib=yes
# Ensure that this version is properly tagged in the repository, just in case upstream lacks a tag
$version = Get-Content 'config.msvc' | Where-Object { $_ -match 'LIBXML_' } | ConvertFrom-StringData
$tagname = 'libxml-' + $version.LIBXML_MAJOR_VERSION + '.' + $version.LIBXML_MINOR_VERSION + '.' + $version.LIBXML_MICRO_VERSION
cmd /c "git tag $tagname -a -m $tagname 2>&1"
cmd /c "nmake 2>&1"
$xmlLib = Join-Path (pwd) bin.msvc
$xmlInc = Join-Path (pwd) ..\include
Set-Location ..\..

Set-Location .\libxslt\win32
cscript configure.js lib="$zlibLib;$iconvLib;$xmlLib" include="$zlibInc;$iconvInc;$xmlInc" vcmanifest=yes zlib=yes
# Ensure that this version is properly tagged in the repository, just in case upstream lacks a tag
$version = Get-Content 'config.msvc' | Where-Object { $_ -match 'LIBXSLT_' } | ConvertFrom-StringData
$tagname = 'libxslt-' + $version.LIBXSLT_MAJOR_VERSION + '.' + $version.LIBXSLT_MINOR_VERSION + '.' + $version.LIBXSLT_MICRO_VERSION
cmd /c "git tag $tagname -a -m $tagname 2>&1"
cmd /c "nmake 2>&1"
Set-Location ..\..

if($vs2008) {
    # Pushed by Import-VisualStudioVars
    Pop-EnvironmentBlock
}

# Bundle releases
Function BundleRelease($name, $lib, $inc)
{
    $name = & cmd /c '--%' "cd $name & git describe --long"
    $name = "$name.$distname"

    New-Item -ItemType Directory .\dist\$name

    Copy-Item -Recurse $lib .\dist\$name
    Get-ChildItem -File -Recurse .\dist\$name | Where{$_.Name -NotMatch "^([^_]+\.exe|[^_]+\.dll)$" } | Remove-Item

    New-Item -ItemType Directory .\dist\$name\lib
    Copy-Item -Recurse $lib .\dist\$name\lib
    Get-ChildItem -File -Recurse .\dist\$name\lib | Where{$_.Name -NotMatch "^([^_]+\.lib|[^_]+\.pdb)$" } | Remove-Item

    New-Item -ItemType Directory .\dist\$name\include
    Copy-Item -Recurse $inc .\dist\$name\include
    Get-ChildItem -File -Recurse .\dist\$name\include | Where{$_.Name -NotMatch "\.h$" } | Remove-Item

    7z a dist\$name.7z dist\$name\.
    Remove-Item -Recurse -Path .\dist\$name
}

if (Test-Path .\dist) { Remove-Item .\dist -Recurse }
New-Item -ItemType Directory .\dist

BundleRelease "libiconv" (dir $iconvLib\libiconv*) (dir $iconvInc\*)
BundleRelease "libxml2" (dir $xmlLib\*) (Get-Item $xmlInc\libxml)
BundleRelease "libxslt" (dir .\libxslt\win32\bin.msvc\*) (Get-Item .\libxslt\libxslt,.\libxslt\libexslt)
BundleRelease "zlib" (Get-Item .\zlib\*.*) (Get-Item .\zlib\zconf.h,.\zlib\zlib.h)
