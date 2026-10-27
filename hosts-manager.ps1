# TunnelWizard's Windows-only hosts manager. Never accepts a destination path:
# the only file this helper can change is the real Windows hosts file.
param(
    [ValidateSet('Preview', 'Commit', 'Elevated')][string]$Mode = 'Preview',
    [ValidateSet('Sync', 'Remove')][string]$Action = 'Sync',
    [string]$ExpectedHash = '',
    [string]$Payload = '',
    [string]$PayloadRoot = ''
)

$ErrorActionPreference = 'Stop'
$elevatedPayloadPath = $null
$markerPattern = '^# TunnelWizard (BEGIN|END) hosts ([A-Za-z0-9._-]+) ([0-9a-f]{64})$'
$hostsPath = Join-Path ([Environment]::SystemDirectory) 'drivers\etc\hosts'

function Get-Address([string]$name) {
    [long]$hash = 0
    foreach ($c in $name.ToLowerInvariant().ToCharArray()) {
        $hash = ($hash * 131 + [int]$c) % 16387064
    }
    return '127.{0}.{1}.{2}' -f ([int][math]::Floor($hash / 64516) + 1),
        ([int][math]::Floor($hash / 254) % 254 + 1), ([int]($hash % 254) + 1)
}

function Test-LoopbackAddress([string]$address) {
    $parsed = $null
    return [Net.IPAddress]::TryParse($address, [ref]$parsed) -and
        $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
        $parsed.GetAddressBytes()[0] -eq 127 -and $parsed.ToString() -ceq $address
}

function Test-Hostname([string]$name) {
    if ($name.Length -gt 253 -or $name -cnotmatch '^[a-z0-9.-]+$' -or
        $name -match '^\.|\.$|\.\.' -or $name -match '^[0-9]+(\.[0-9]+){3}$') {
        return $false
    }
    foreach ($part in $name.Split('.')) {
        if ($part.Length -gt 63 -or $part -cnotmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') {
            return $false
        }
    }
    return $true
}

function Get-Context([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) {
        throw 'The config must have a canonical absolute Windows path.'
    }
    $canonical = [IO.Path]::GetFullPath($path).ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $label = [IO.Path]::GetFileName($canonical) -replace '[^a-z0-9._-]', '_'
    if (-not $label) { throw 'Invalid config filename.' }
    return [pscustomobject]@{ Key = $key; Label = $label }
}

function Get-Entries([object[]]$items) {
    $names = @{}
    $ips = @{}
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $items) {
        $name = [string]$item.Name
        $ip = [string]$item.IP
        if (-not (Test-Hostname $name) -or $name -cne $name.ToLowerInvariant() -or
            -not (Test-LoopbackAddress $ip)) {
            throw "Invalid hostname or IPv4 loopback address: $name $ip"
        }
        if ($names.ContainsKey($name) -or $ips.ContainsKey($ip)) {
            throw "Duplicate hostname or loopback address: $name $ip"
        }
        $names[$name] = $true
        $ips[$ip] = $true
        $result.Add([pscustomobject]@{ Name = $name; IP = $ip })
    }
    return ,$result.ToArray()
}

function Read-Hosts {
    if (-not [IO.File]::Exists($hostsPath) -or
        (([IO.File]::GetAttributes($hostsPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Windows hosts file is missing or is a reparse point.'
    }
    $bytes = [IO.File]::ReadAllBytes($hostsPath)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $bom = [byte[]]@()
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $bom = [byte[]]@(239, 187, 191)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        $bom = [byte[]]@(255, 254)
        $encoding = New-Object Text.UnicodeEncoding($false, $false, $true)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
        $bom = [byte[]]@(254, 255)
        $encoding = New-Object Text.UnicodeEncoding($true, $false, $true)
    } elseif ($bytes.Length -ge 2 -and ($bytes.Length % 2) -eq 0) {
        # Some Windows hosts files are UTF-16 without a BOM. Detect the
        # alternating NUL bytes before trying strict UTF-8.
        $evenZeros = 0
        $oddZeros = 0
        for ($i = 0; $i -lt $bytes.Length; $i += 2) {
            if ($bytes[$i] -eq 0) { $evenZeros++ }
            if ($bytes[$i + 1] -eq 0) { $oddZeros++ }
        }
        if ($oddZeros -gt [math]::Floor($bytes.Length / 4) -and $oddZeros -gt $evenZeros) {
            $encoding = New-Object Text.UnicodeEncoding($false, $false, $true)
        } elseif ($evenZeros -gt [math]::Floor($bytes.Length / 4) -and $evenZeros -gt $oddZeros) {
            $encoding = New-Object Text.UnicodeEncoding($true, $false, $true)
        }
    }
    $text = $encoding.GetString($bytes, $bom.Length, $bytes.Length - $bom.Length)
    if ($text.IndexOf([char]0) -ge 0) { throw 'Hosts file contains invalid NUL characters.' }
    $lines = New-Object 'System.Collections.Generic.List[object]'
    foreach ($m in [regex]::Matches($text, '[^\r\n]*(?:\r\n|\r|\n|$)')) {
        if ($m.Length -eq 0) { continue }
        $lines.Add([pscustomobject]@{ Raw = $m.Value; Value = $m.Value.TrimEnd([char[]]@("`r", "`n")) })
    }
    $newline = "`r`n"
    if ($text -match '\r\n|\r|\n') { $newline = $Matches[0] }
    return [pscustomobject]@{ Lines = $lines.ToArray(); Encoding = $encoding; Bom = $bom;
        Hash = $hash; Newline = $newline; Text = $text }
}

function New-Plan($state, $context, [object[]]$entries, [string]$operation) {
    $begin = '# TunnelWizard BEGIN hosts {0} {1}' -f $context.Label, $context.Key
    $end = '# TunnelWizard END hosts {0} {1}' -f $context.Label, $context.Key
    $start = -1
    $finish = -1
    $open = $null
    $seen = @{}
    $outsideNames = @{}
    $outsideIps = @{}
    $blockNames = @{}
    $blockIps = @{}
    $lineNumber = 0
    foreach ($line in $state.Lines) {
        $text = $line.Value
        if ($text -match '^\s*#\s*TunnelWizard\s+(BEGIN|END)\b') {
            if (-not ($text -cmatch $markerPattern)) { throw "Malformed TunnelWizard marker on line $($lineNumber + 1)." }
            $kind, $label, $key = $Matches[1], $Matches[2], $Matches[3]
            if ($kind -eq 'BEGIN') {
                if ($null -ne $open -or $seen.ContainsKey($key)) { throw 'Nested or duplicate TunnelWizard block.' }
                $seen[$key] = $true
                $open = [pscustomobject]@{ Key = $key; Label = $label; Start = $lineNumber }
                if ($key -eq $context.Key) {
                    if ($text -cne $begin) { throw 'Config marker label does not match this config path.' }
                    $start = $lineNumber
                }
            } else {
                if ($null -eq $open -or $key -cne $open.Key -or $label -cne $open.Label) {
                    throw 'Unmatched or mismatched TunnelWizard marker.'
                }
                if ($key -eq $context.Key) { $finish = $lineNumber }
                $open = $null
            }
        } elseif ($null -ne $open) {
            if (-not ($text -cmatch '^(127\.[0-9]+\.[0-9]+\.[0-9]+) ([a-z0-9.-]+)$')) {
                throw "Invalid managed hosts entry on line $($lineNumber + 1)."
            }
            $ip, $name = $Matches[1], $Matches[2]
            if (-not (Test-Hostname $name) -or -not (Test-LoopbackAddress $ip) -or
                $blockNames.ContainsKey($name) -or $blockIps.ContainsKey($ip)) {
                throw "Conflicting or invalid managed entry: $text"
            }
            $blockNames[$name] = $true
            $blockIps[$ip] = $true
        } elseif ($text -match '^\s*([^\s#]+)\s+([^#]+)') {
            $ip = $Matches[1]
            $aliases = ($Matches[2] -split '\s+')
            foreach ($alias in $aliases) {
                if ($alias) { $outsideNames[$alias.ToLowerInvariant()] = $true }
            }
            $parsedIp = $null
            if ([Net.IPAddress]::TryParse($ip, [ref]$parsedIp) -and
                $parsedIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                $parsedIp.GetAddressBytes()[0] -eq 127) {
                $outsideIps[$parsedIp.ToString()] = $true
            }
        }
        $lineNumber++
    }
    if ($null -ne $open -or ($start -ge 0 -and $finish -lt 0)) {
        throw 'Unclosed TunnelWizard block.'
    }
    # All other managed blocks are also checked, regardless of their order.
    foreach ($entry in $entries) {
        if ($outsideNames.ContainsKey($entry.Name) -or $outsideIps.ContainsKey($entry.IP)) {
            throw "Hosts entry outside this config already uses $($entry.Name) or $($entry.IP)."
        }
        if ($start -lt 0 -and ($blockNames.ContainsKey($entry.Name) -or $blockIps.ContainsKey($entry.IP))) {
            throw "Another config already uses $($entry.Name) or $($entry.IP)."
        }
    }
    # Re-scan other blocks; own old entries may be removed during sync.
    $otherNames = @{}
    $otherIps = @{}
    $inside = $false
    $own = $false
    foreach ($line in $state.Lines) {
        if ($line.Value -cmatch $markerPattern) {
            if ($Matches[1] -eq 'BEGIN') { $inside = $true; $own = ($Matches[3] -eq $context.Key) }
            else { $inside = $false; $own = $false }
        } elseif ($inside -and -not $own) {
            $parts = $line.Value.Split(' ')
            $otherIps[$parts[0]] = $true
            $otherNames[$parts[1]] = $true
        }
    }
    foreach ($entry in $entries) {
        if ($otherNames.ContainsKey($entry.Name) -or $otherIps.ContainsKey($entry.IP)) {
            throw "Another config already uses $($entry.Name) or $($entry.IP)."
        }
    }
    $added = New-Object 'System.Collections.Generic.List[string]'
    if ($operation -eq 'Sync' -and $entries.Length -gt 0) {
        $added.Add($begin)
        foreach ($entry in $entries) { $added.Add("$($entry.IP) $($entry.Name)") }
        $added.Add($end)
    }
    $removed = New-Object 'System.Collections.Generic.List[string]'
    $output = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $state.Lines.Length; $i++) {
        if ($i -eq $start) {
            for ($j = $start; $j -le $finish; $j++) { $removed.Add($state.Lines[$j].Value) }
            foreach ($newLine in $added) { [void]$output.Append($newLine + $state.Newline) }
            $i = $finish
        } else { [void]$output.Append($state.Lines[$i].Raw) }
    }
    if ($start -lt 0 -and $added.Count -gt 0) {
        if ($state.Text.Length -gt 0 -and $state.Text -cnotmatch '(\r\n|\r|\n)$') {
            throw 'Hosts file has no final newline; add one manually before appending a block.'
        }
        foreach ($newLine in $added) { [void]$output.Append($newLine + $state.Newline) }
    }
    return [pscustomobject]@{ Text = $output.ToString(); Added = $added.ToArray();
        Removed = $removed.ToArray(); Changed = ($output.ToString() -cne $state.Text) }
}

function Write-Hosts($state, $plan) {
    if (-not $plan.Changed) { return 0 }
    $body = $state.Encoding.GetBytes($plan.Text)
    $bytes = New-Object byte[] ($state.Bom.Length + $body.Length)
    [Array]::Copy($state.Bom, 0, $bytes, 0, $state.Bom.Length)
    [Array]::Copy($body, 0, $bytes, $state.Bom.Length, $body.Length)
    $directory = Split-Path $hostsPath
    $temp = Join-Path $directory ([IO.Path]::GetRandomFileName())
    $backup = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllBytes($temp, $bytes)
        # Windows PowerShell/.NET Framework can reject a null backup path;
        # provide a same-directory backup to keep Replace atomic and portable.
        [IO.File]::Replace($temp, $hostsPath, $backup)
    } finally {
        if ([IO.File]::Exists($temp)) {
            try { [IO.File]::Delete($temp) } catch { }
        }
        if ([IO.File]::Exists($backup)) {
            try { [IO.File]::Delete($backup) }
            catch {
                [Console]::Error.WriteLine("TunnelWizard hosts: could not remove temporary backup '$backup': $($_.Exception.Message)")
            }
        }
    }
    try {
        & ipconfig.exe /flushdns | Out-Null
        if ($LASTEXITCODE -ne 0) { return 3 }
    } catch { return 3 }
    return 0
}

try {
    if ($Mode -eq 'Elevated') {
        $tempRoot = [IO.Path]::GetFullPath($PayloadRoot)
        $tempRootPrefix = $tempRoot.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
        $payloadPath = [IO.Path]::GetFullPath($Payload)
        $payloadDirectory = [IO.Path]::GetDirectoryName($payloadPath)
        if (-not $payloadPath.StartsWith($tempRootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            $payloadDirectory.TrimEnd([char[]]@('\', '/')) -ine $tempRoot.TrimEnd([char[]]@('\', '/')) -or
            -not [IO.File]::Exists($payloadPath) -or
            (([IO.File]::GetAttributes($payloadPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Invalid temporary payload.'
        }
        $elevatedPayloadPath = $payloadPath
        $request = [IO.File]::ReadAllText($payloadPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $Action = [string]$request.Action
        $ExpectedHash = [string]$request.Hash
        if ($Action -notin @('Sync', 'Remove')) { throw 'Invalid operation.' }
        $path = [string]$request.Path
        # Windows PowerShell 5.1 deserializes JSON [] as $null.
        if ($null -eq $request.Entries) { $items = @() }
        else { $items = @($request.Entries) }
    } else {
        $path = $env:WIZARD_CONTEXT_PATH
        $items = @()
        if ($env:WIZARD_HOSTS) {
            foreach ($line in ($env:WIZARD_HOSTS -split "`n")) {
                if (-not ($line -cmatch '^([a-z0-9.-]+) (127\.[0-9]+\.[0-9]+\.[0-9]+)$')) {
                    throw 'Invalid hostname list passed by the wizard.'
                }
                $items += [pscustomobject]@{ Name = $Matches[1]; IP = $Matches[2] }
            }
        }
    }
    $context = Get-Context $path
    $entries = Get-Entries $items
    $state = Read-Hosts
    if ($Mode -ne 'Preview' -and $state.Hash -cne $ExpectedHash) {
        throw 'Hosts file changed since preview; review again before applying.'
    }
    $plan = New-Plan $state $context $entries $Action
    if ($Mode -eq 'Preview') {
        Write-Output "Config block: $($context.Label) ($($context.Key))"
        Write-Output "Operation: $Action"
        if (-not $plan.Changed) { Write-Output 'No changes needed.' }
        foreach ($line in $plan.Removed) { Write-Output "- $line" }
        foreach ($line in $plan.Added) { Write-Output "+ $line" }
        Write-Output "SNAPSHOT=$($state.Hash)"
        exit 0
    }
    if ($Mode -eq 'Elevated' -or ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        exit (Write-Hosts $state $plan)
    }
    $tempFile = [IO.Path]::GetTempFileName()
    try {
        # Only the current user, SYSTEM and Administrators can read this payload.
        $acl = Get-Acl -LiteralPath $tempFile
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
        foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
                          ([Security.Principal.SecurityIdentifier]::new('S-1-5-18')),
                          ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')))) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $tempFile -AclObject $acl
        $json = @{ Path = $path; Entries = @($entries); Action = $Action; Hash = $ExpectedHash } | ConvertTo-Json -Depth 5 -Compress
        [IO.File]::WriteAllText($tempFile, $json, (New-Object Text.UTF8Encoding($false)))
        $payloadRoot = [IO.Path]::GetDirectoryName($tempFile)
        $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Elevated -Payload "{1}" -PayloadRoot "{2}"' -f $PSCommandPath, $tempFile, $payloadRoot
        try {
            $child = Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList $args -Wait -PassThru -ErrorAction Stop
        } catch {
            if ($_.Exception.HResult -eq -2147023673 -or $_.Exception.Message -match 'cancel') { exit 4 }
            throw
        }
        if ($null -eq $child.ExitCode) { exit 4 }
        if ($child.ExitCode -ne 0 -and $child.ExitCode -ne 3 -and $child.ExitCode -ne 4) {
            $detail = [IO.File]::ReadAllText($tempFile, [Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($detail) -and $detail -notmatch '^\s*\{') {
                [Console]::Error.WriteLine("Elevated hosts helper: $detail")
            } else {
                [Console]::Error.WriteLine("Elevated hosts helper exited with code $($child.ExitCode) without diagnostic details.")
            }
        }
        exit $child.ExitCode
    } finally { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
} catch {
    if ($Mode -eq 'Elevated' -and $elevatedPayloadPath) {
        try {
            [IO.File]::WriteAllText($elevatedPayloadPath, $_.Exception.ToString(), (New-Object Text.UTF8Encoding($false)))
        } catch { }
    }
    [Console]::Error.WriteLine("TunnelWizard hosts: $($_.Exception.ToString())")
    exit 1
}
