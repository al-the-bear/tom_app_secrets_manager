# Makes the self-signed code-signing certificate the Windows release's MSIX
# package is signed with, and the signing properties file ci.ps1 :release
# reads (TSM_WINDOWS_SIGNING). Run once, by a person, on the machine that
# builds releases. Nothing here needs an administrator.
#
#   .\new_signing_certificate.ps1 -OutDir C:\Users\me\tsm-signing
#
# Writes into OutDir (keep it outside every repository):
#   tsm-signing.pfx         the certificate with its private key
#   tsm-signing.cer         the public certificate, for each machine's
#                           Trusted People store (install_signing_certificate.ps1)
#   signing.properties      certificateFile, certificatePassword, publisher
#
# Then: $env:TSM_WINDOWS_SIGNING = "<OutDir>\signing.properties"
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Subject = 'CN=Tom Secrets Manager',
    [int]$Years = 3
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# A code-signing certificate (EKU 1.3.6.1.5.5.7.3.3) that is no CA.
$cert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $Subject `
    -KeyUsage DigitalSignature `
    -KeyAlgorithm RSA -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -FriendlyName 'Tom Secrets Manager package signing' `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -NotAfter (Get-Date).AddYears($Years) `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')

# A random password for the .pfx, kept only in the properties file.
$bytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$password = [Convert]::ToBase64String($bytes) -replace '[+/=]', 'x'
$secure = ConvertTo-SecureString -String $password -Force -AsPlainText

$pfx = Join-Path $OutDir 'tsm-signing.pfx'
$cer = Join-Path $OutDir 'tsm-signing.cer'
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null
Export-Certificate -Cert $cert -FilePath $cer | Out-Null
# The private key stays only in the .pfx.
Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)"

$properties = Join-Path $OutDir 'signing.properties'
@(
    '# The Windows release signing (tom_secrets_build, TSM_WINDOWS_SIGNING).',
    "certificateFile=$pfx",
    "certificatePassword=$password",
    "publisher=$Subject"
) | Set-Content -Path $properties -Encoding ascii

Write-Output "certificate $($cert.Thumbprint), valid until $($cert.NotAfter.ToString('yyyy-MM-dd'))"
Write-Output "wrote $pfx, $cer and $properties"
Write-Output "set TSM_WINDOWS_SIGNING=$properties; install $cer on each machine with install_signing_certificate.ps1"
