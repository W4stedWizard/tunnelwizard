# Install a public key for Windows OpenSSH administrator accounts.
# Run from an elevated PowerShell session on the SSH server.
# Without -PublicKeyPath, the script prompts for one pasted public-key line.
# Usage: .\install-windows-admin-ssh-key.ps1 [-PublicKeyPath <copied .pub file>]
# This intentionally targets administrators_authorized_keys, not a user's
# profile .ssh\authorized_keys file.
# The file is shared by Windows OpenSSH administrator accounts.
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$PublicKeyPath
)

$ErrorActionPreference = 'Stop'

if ($PublicKeyPath) {
    $keyLines = @(
        Get-Content -LiteralPath $PublicKeyPath -ErrorAction Stop |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    if ($keyLines.Count -ne 1) {
        throw 'The public-key file must contain exactly one non-empty key line.'
    }
    $publicKey = $keyLines[0]
} else {
    $publicKey = (Read-Host 'Paste the complete, single-line public key').Trim()
}

$keyPattern = '^(?<Type>ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp\d+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\s+(?<Blob>[A-Za-z0-9+/]+={0,2})(?:\s+.*)?$'
if ($publicKey -match $keyPattern) {
    $keyBlob = $Matches['Blob']
} else {
    throw 'Invalid or unsupported SSH public-key line. Expected an Ed25519, RSA, ECDSA, or supported security-key public key.'
}

try {
    [void][Convert]::FromBase64String($keyBlob)
} catch {
    throw 'The public key contains invalid base64 key data.'
}

$sshDirectory = Join-Path $env:ProgramData 'ssh'
$authorizedKeys = Join-Path $sshDirectory 'administrators_authorized_keys'
$keyFileExists = Test-Path -LiteralPath $authorizedKeys -PathType Leaf

if ($keyFileExists) {
    Write-Host "Existing administrator key file found: $authorizedKeys"
    Write-Host 'Its key contents will be preserved, but its ACL will be replaced with the Windows OpenSSH-required Administrators/SYSTEM ACL.'
    & icacls.exe $authorizedKeys
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect the existing authorized-key file ACL.'
    }
    $answer = Read-Host 'Continue and replace this file ACL? [y/N]'
    if ($answer -notmatch '^(?i:y|yes)$') {
        Write-Host 'Cancelled; no changes were made.'
        return
    }
}

if (-not (Test-Path -LiteralPath $sshDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $sshDirectory | Out-Null
}

if (-not $keyFileExists) {
    New-Item -ItemType File -Path $authorizedKeys | Out-Null
}

$existingKeys = @(Get-Content -LiteralPath $authorizedKeys -ErrorAction Stop)
if ($existingKeys -cnotcontains $publicKey) {
    Add-Content -LiteralPath $authorizedKeys -Value $publicKey -Encoding ascii
    Write-Host 'Added the public key.'
} else {
    Write-Host 'That public key is already installed.'
}

# Replace inherited/custom ACLs, then grant access only to the built-in
# Administrators group and SYSTEM. SIDs work across Windows locales. Existing
# file ACLs are shown and require confirmation above; key contents are preserved.
$aclOutput = & icacls.exe $authorizedKeys /reset 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not reset the authorized-key file ACL: $($aclOutput -join ' ')"
}

$aclOutput = & icacls.exe $authorizedKeys /inheritance:r `
    /grant:r '*S-1-5-32-544:F' /grant:r '*S-1-5-18:F' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not set the authorized-key file ACL: $($aclOutput -join ' ')"
}

if (-not (Select-String -LiteralPath $authorizedKeys -SimpleMatch $publicKey -Quiet)) {
    throw 'The public key was not found in the administrator authorized-keys file after installation.'
}

Write-Host "Administrator authorized keys: $authorizedKeys"
Write-Host 'Authorized-key ACL:'
& icacls.exe $authorizedKeys
if ($LASTEXITCODE -ne 0) {
    throw 'Could not display the authorized-key file ACL.'
}

Write-Host 'Done. No sshd restart is needed for an authorized_keys change.'
