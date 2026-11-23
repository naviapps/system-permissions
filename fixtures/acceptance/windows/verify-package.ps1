param(
    [Parameter(Mandatory = $true)][string] $Work,
    [Parameter(Mandatory = $true)][string] $SdkBin,
    [Parameter(Mandatory = $true)][string] $Fixture,
    [Parameter(Mandatory = $true)][string] $Library
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') {
    throw 'The MSIX fixture requires a disposable GitHub-hosted Windows runner.'
}

$suffix = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$identity = "NaviApps.SystemPermissions.Test.$suffix"
$publisher = "CN=$identity"
$alias = "system-permissions-$suffix.exe"
$layout = Join-Path $Work 'layout'
$package = Join-Path $Work 'permissions.msix'
$certificatePath = Join-Path $Work 'fixture.cer'
$makeAppx = Join-Path $SdkBin 'makeappx.exe'
$signTool = Join-Path $SdkBin 'signtool.exe'

New-Item -ItemType Directory -Path $layout | Out-Null
Copy-Item -LiteralPath $Fixture -Destination (Join-Path $layout 'abi.exe')
Copy-Item -LiteralPath $Library -Destination (Join-Path $layout 'system_permissions.dll')
Add-Type -AssemblyName System.Drawing
foreach ($size in 44, 50, 150) {
    $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $size, $size
    try { $bitmap.Save((Join-Path $layout "Logo$size.png"), [Drawing.Imaging.ImageFormat]::Png) }
    finally { $bitmap.Dispose() }
}

@"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:uap5="http://schemas.microsoft.com/appx/manifest/uap/windows10/5"
  xmlns:uap10="http://schemas.microsoft.com/appx/manifest/uap/windows10/10"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  IgnorableNamespaces="uap uap5 uap10 rescap">
  <Identity Name="$identity" Publisher="$publisher" Version="1.0.0.0" ProcessorArchitecture="x64"/>
  <Properties>
    <DisplayName>SystemPermissions Test</DisplayName>
    <PublisherDisplayName>Navi Apps LLC</PublisherDisplayName>
    <Logo>Logo50.png</Logo>
  </Properties>
  <Resources><Resource Language="en-us"/></Resources>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.26100.0" MaxVersionTested="10.0.26100.0"/>
  </Dependencies>
  <Applications>
    <Application Id="Fixture" Executable="abi.exe" uap10:RuntimeBehavior="packagedClassicApp" uap10:TrustLevel="mediumIL">
      <uap:VisualElements DisplayName="SystemPermissions Test" Description="SDK package identity fixture"
        Square150x150Logo="Logo150.png" Square44x44Logo="Logo44.png" BackgroundColor="transparent"/>
      <Extensions>
        <uap5:Extension Category="windows.appExecutionAlias">
          <uap5:AppExecutionAlias uap10:Subsystem="console">
            <uap5:ExecutionAlias Alias="$alias"/>
          </uap5:AppExecutionAlias>
        </uap5:Extension>
      </Extensions>
    </Application>
  </Applications>
  <Capabilities>
    <rescap:Capability Name="runFullTrust"/>
    <DeviceCapability Name="webcam"/>
  </Capabilities>
</Package>
"@ | Set-Content (Join-Path $layout 'AppxManifest.xml') -Encoding UTF8

& $makeAppx pack /d $layout /p $package
if ($LASTEXITCODE -ne 0) { throw "MSIX creation failed ($LASTEXITCODE)." }

$certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject $publisher `
    -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(1)
$thumbprint = $certificate.Thumbprint
$trusted = "Cert:\LocalMachine\TrustedPeople\$thumbprint"
try {
    Export-Certificate -Cert $certificate -FilePath $certificatePath | Out-Null
    Import-Certificate -FilePath $certificatePath -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
    & $signTool sign /fd SHA256 /sha1 $thumbprint $package
    if ($LASTEXITCODE -ne 0) { throw "MSIX signing failed ($LASTEXITCODE)." }
    Add-AppxPackage -Path $package
    $installed = @(Get-AppxPackage -Name $identity)
    if ($installed.Count -ne 1 -or $installed[0].Architecture -ne 'X64') {
        throw 'The expected x64 MSIX registration was not found.'
    }
    $executable = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$alias"
    & $executable $installed[0].PackageFullName
    if ($LASTEXITCODE -ne 0) { throw "MSIX desktop acceptance failed ($LASTEXITCODE)." }
}
finally {
    try {
        Get-AppxPackage -Name $identity | ForEach-Object {
            Remove-AppxPackage -Package $_.PackageFullName
        }
        if (Get-AppxPackage -Name $identity) { throw 'MSIX fixture remains installed.' }
    }
    finally {
        try {
            if (Test-Path -LiteralPath $trusted) { Remove-Item -LiteralPath $trusted }
        }
        finally { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -DeleteKey }
    }
}
