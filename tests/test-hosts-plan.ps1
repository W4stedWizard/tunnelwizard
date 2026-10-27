# Windows PowerShell: exercise pure planning functions against in-memory hosts
# fixtures. Do not call the helper entry point or touch the real hosts file.
$ErrorActionPreference = 'Stop'
$helper = Join-Path (Split-Path $PSScriptRoot) 'hosts-manager.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "PowerShell parse errors: $errors" }
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($node.Extent.Text))
}
$markerPattern = '^# TunnelWizard (BEGIN|END) hosts ([A-Za-z0-9._-]+) ([0-9a-f]{64})$'

function Assert($condition, $message) { if (-not $condition) { throw $message } }
function State([string]$text) {
    $lines = @()
    foreach ($m in [regex]::Matches($text, '[^\r\n]*(?:\r\n|\r|\n|$)')) {
        if ($m.Length -gt 0) {
            $lines += [pscustomobject]@{ Raw = $m.Value; Value = $m.Value.TrimEnd([char[]]@("`r", "`n")) }
        }
    }
    return [pscustomobject]@{ Text = $text; Lines = $lines; Newline = "`r`n" }
}

$first = Get-Context 'C:\users\one\same.conf'
$second = Get-Context 'C:\users\two\same.conf'
Assert ($first.Key -ne $second.Key) 'Duplicate basenames must have distinct marker keys.'
Assert ((Get-Address 'pmx-one') -ceq '127.105.144.115') 'Address mapping differs from the Bash implementation.'
$entry = Get-Entries @([pscustomobject]@{ Name = 'pmx-one'; IP = (Get-Address 'pmx-one') })
Assert ((Get-Entries @([pscustomobject]@{ Name = 'pmx-custom'; IP = '127.0.0.66' })).Length -eq 1) `
    'Explicit loopback binds must be accepted as local hostname addresses.'
$old = "# unrelated`r`n127.0.0.1 localhost`r`n"
$other = "# TunnelWizard BEGIN hosts $($second.Label) $($second.Key)`r`n" +
    "$(Get-Address 'pmx-two') pmx-two`r`n" +
    "# TunnelWizard END hosts $($second.Label) $($second.Key)`r`n"
$base = $old + $other + "# end`r`n"
$added = New-Plan (State $base) $first $entry 'Sync'
Assert ($added.Text.StartsWith($base)) 'Sync must preserve unrelated lines and other blocks.'
Assert ($added.Added.Count -eq 3) 'Expected two markers and one mapping.'
$updated = New-Plan (State $added.Text) $first @() 'Remove'
Assert ($updated.Text -ceq $base) 'Remove must restore all unrelated lines byte-for-byte.'
$repeat = New-Plan (State $added.Text) $first $entry 'Sync'
Assert (-not $repeat.Changed) 'Identical sync must be a no-op.'

$conflict = $base + "$(Get-Address 'pmx-one') stranger`r`n"
try { $null = New-Plan (State $conflict) $first $entry 'Sync'; throw 'Expected outside-IP conflict.' }
catch { if ($_.Exception.Message -eq 'Expected outside-IP conflict.') { throw } }
$conflict = $base + "192.0.2.1 pmx-one`r`n"
try { $null = New-Plan (State $conflict) $first $entry 'Sync'; throw 'Expected outside-hostname conflict.' }
catch { if ($_.Exception.Message -eq 'Expected outside-hostname conflict.') { throw } }
$nested = $base + "# TunnelWizard BEGIN hosts $($first.Label) $($first.Key)`r`n" +
    "# TunnelWizard BEGIN hosts $($second.Label) $($second.Key)`r`n"
try { $null = New-Plan (State $nested) $first $entry 'Sync'; throw 'Expected nested marker rejection.' }
catch { if ($_.Exception.Message -eq 'Expected nested marker rejection.') { throw } }
$invalid = $base + "# TunnelWizard BEGIN hosts $($first.Label) $($first.Key)`r`n" +
    "0.0.0.1 pmx-one`r`n# TunnelWizard END hosts $($first.Label) $($first.Key)`r`n"
try { $null = New-Plan (State $invalid) $first $entry 'Sync'; throw 'Expected invalid payload rejection.' }
catch { if ($_.Exception.Message -eq 'Expected invalid payload rejection.') { throw } }

# BOM-less UTF-16 hosts files are read without changing their encoding.
$tempHosts = [IO.Path]::GetTempFileName()
try {
    $utf16Text = "127.0.0.1 localhost`r`n"
    $utf16 = New-Object Text.UnicodeEncoding($false, $false)
    [IO.File]::WriteAllBytes($tempHosts, $utf16.GetBytes($utf16Text))
    $hostsPath = $tempHosts
    $decoded = Read-Hosts
    Assert ($decoded.Text -ceq $utf16Text) 'BOM-less UTF-16LE hosts file was not decoded.'
    Assert ($decoded.Bom.Length -eq 0) 'BOM-less UTF-16LE should remain BOM-less.'
} finally {
    Remove-Item -LiteralPath $tempHosts -Force -ErrorAction SilentlyContinue
}
Write-Output 'Hosts planning tests passed.'
