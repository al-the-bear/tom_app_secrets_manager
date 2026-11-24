# Lets this machine install the Tom Secrets Manager's MSIX package: puts the
# package's self-signed certificate (tsm-signing.cer, made by
# new_signing_certificate.ps1) into the machine's Trusted People store.
# Run once per machine, by a person, in an administrator PowerShell:
#
#   .\install_signing_certificate.ps1 -Certificate C:\path\tsm-signing.cer
#
# Only the public certificate is installed; it trusts packages signed with
# this one certificate and nothing else (Trusted People, not a root).
# Remove it again with:
#   Get-ChildItem Cert:\LocalMachine\TrustedPeople |
#     Where-Object Subject -eq 'CN=Tom Secrets Manager' | Remove-Item
param(
    [Parameter(Mandatory = $true)][string]$Certificate
)

$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [Console]::Error.WriteLine('install_signing_certificate.ps1: run it in an administrator PowerShell')
    exit 2
}
$imported = Import-Certificate -FilePath $Certificate -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'
Write-Output "installed $($imported.Subject) ($($imported.Thumbprint)) into Trusted People"
