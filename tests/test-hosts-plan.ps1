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
function DiffSignature([object[]]$rows) {
    $parts = @()
    foreach ($row in $rows) { $parts += "$($row.Kind):$($row.Text)" }
    return ($parts -join "`n")
}
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
$manual = Get-Entries @([pscustomobject]@{ Name = 'pmx-manual'; IP = '127.0.0.66' })
$missing = Get-Entries @([pscustomobject]@{ Name = 'pmx-missing'; IP = '127.0.0.67' })
$conflicting = Get-Entries @([pscustomobject]@{ Name = 'pmx-conflict'; IP = '127.0.0.68' })
$checkEntries = @($entry[0], $manual[0], $missing[0], $conflicting[0])
$checkText = $added.Text + "127.0.0.66 localhost-alias PMX-MANUAL # maintained by hand`r`n" +
    "127.0.0.69 pmx-conflict`r`n"
$presence = Get-HostsPresence (State $checkText) $checkEntries
Assert ($presence.Count -eq 4 -and $presence[0].Status -eq 'PRESENT' -and
    $presence[1].Status -eq 'PRESENT' -and $presence[2].Status -eq 'ABSENT' -and
    $presence[3].Status -eq 'CONFLICT') `
    'Presence must recognize managed/manual mappings and distinguish missing from conflicting names.'
$duplicate = Get-HostsPresence (State ($checkText + "192.0.2.1 PMX-ONE`r`n")) $checkEntries
Assert ($duplicate[0].Status -eq 'CONFLICT') 'A conflicting mapping must override an exact mapping.'
$updated = New-Plan (State $added.Text) $first @() 'Remove'
Assert ($updated.Text -ceq $base) 'Remove must restore all unrelated lines byte-for-byte.'
Assert ($updated.Diff.Count -eq 3 -and @($updated.Diff | Where-Object Kind -ne 'Remove').Count -eq 0) `
    'Current-config removal must show only its three removed block lines.'
$repeat = New-Plan (State $added.Text) $first $entry 'Sync'
Assert (-not $repeat.Changed) 'Identical sync must be a no-op.'
Assert ($repeat.Diff.Count -eq 3 -and @($repeat.Diff | Where-Object Kind -ne 'Equal').Count -eq 0) `
    'Identical sync must show unchanged marker and entry lines.'

$ordered = Get-DiffRows @('alpha', 'old', 'middle', 'old-end') @('alpha', 'new', 'middle', 'new-end')
Assert ((DiffSignature $ordered) -ceq (@('Equal:alpha', 'Remove:old', 'Add:new',
    'Equal:middle', 'Remove:old-end', 'Add:new-end') -join "`n")) `
    'LCS diff must retain matches and interleave additions and removals in order.'
$retained = Get-Entries @([pscustomobject]@{ Name = 'pmx-retained'; IP = (Get-Address 'pmx-retained') })
$replacement = Get-Entries @([pscustomobject]@{ Name = 'pmx-replacement'; IP = (Get-Address 'pmx-replacement') })
$twoEntries = New-Plan (State $base) $first @($entry[0], $retained[0]) 'Sync'
$sync = New-Plan (State $twoEntries.Text) $first @($replacement[0], $retained[0]) 'Sync'
$begin = "# TunnelWizard BEGIN hosts $($first.Label) $($first.Key)"
$end = "# TunnelWizard END hosts $($first.Label) $($first.Key)"
Assert ((DiffSignature $sync.Diff) -ceq (@(
    "Equal:$begin", "Remove:$($entry[0].IP) pmx-one",
    "Add:$($replacement[0].IP) pmx-replacement",
    "Equal:$($retained[0].IP) pmx-retained", "Equal:$end") -join "`n")) `
    'Sync diff must retain markers and unchanged entries around edits.'

# Removing this config must leave the other block and unrelated bytes intact,
# even when the other block appears before this one in a mixed-newline file.
$mixedPrefix = "# unrelated`n127.0.0.1 localhost`r`n"
$mixedMiddle = "  leave me alone  `r"
$mixedEnd = 'last line without a newline'
$mixed = $mixedPrefix + $other + $mixedMiddle + ($added.Text.Substring($base.Length)) + $mixedEnd
$mixedNoop = $mixedPrefix + $other + $mixedMiddle +
    ($added.Text.Substring($base.Length)).Replace("`r`n", "`n") + $mixedEnd
$sameMixed = New-Plan (State $mixedNoop) $first $entry 'Sync'
Assert (-not $sameMixed.Changed -and $sameMixed.Text -ceq $mixedNoop) `
    'Unchanged sync must preserve existing managed line endings, too.'
$oneRemoved = New-Plan (State $mixed) $first @() 'Remove'
Assert ($oneRemoved.Text -ceq ($mixedPrefix + $other + $mixedMiddle + $mixedEnd)) `
    'Remove must preserve other blocks and all unrelated text, including line endings.'
$allRemoved = New-Plan (State $mixed) $first @() 'RemoveAll'
Assert ($allRemoved.Text -ceq ($mixedPrefix + $mixedMiddle + $mixedEnd)) `
    'RemoveAll must remove every block and preserve unrelated bytes and line endings.'
Assert ($allRemoved.Diff.Count -eq 6 -and @($allRemoved.Diff | Where-Object Kind -ne 'Remove').Count -eq 0) `
    'RemoveAll preview must include both removed blocks, markers included.'
Assert ($allRemoved.Diff[0].Text -ceq "# TunnelWizard BEGIN hosts $($second.Label) $($second.Key)" -and
    $allRemoved.Diff[3].Text -ceq $begin) 'RemoveAll diff must follow file order.'
$emptyAll = New-Plan (State $old) $first @() 'RemoveAll'
Assert (-not $emptyAll.Changed -and $emptyAll.Diff.Count -eq 0 -and $emptyAll.Text -ceq $old) `
    'RemoveAll with no blocks must be an exact no-op.'

# A foreign label for the selected key is still a well-formed block for
# RemoveAll; per-config operations must continue to reject that mismatch.
$renamed = $base + ($added.Text.Substring($base.Length)).Replace($first.Label, 'previous-label.conf')
$renamedAll = New-Plan (State $renamed) $first @() 'RemoveAll'
Assert ($renamedAll.Text -ceq ($old + "# end`r`n")) `
    'RemoveAll must remove every well-formed block without relying on config labels.'
try { $null = New-Plan (State $renamed) $first @() 'Remove'; throw 'Expected selected-label rejection.' }
catch { if ($_.Exception.Message -eq 'Expected selected-label rejection.') { throw } }
$duplicateMapping = $base + "# TunnelWizard BEGIN hosts $($first.Label) $($first.Key)`r`n" +
    "$(Get-Address 'pmx-two') pmx-two`r`n" +
    "# TunnelWizard END hosts $($first.Label) $($first.Key)`r`n"
Assert ((New-Plan (State $duplicateMapping) $first @() 'RemoveAll').Text -ceq ($old + "# end`r`n")) `
    'RemoveAll must remove separately valid blocks even when mappings overlap across configs.'

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
try { $null = New-Plan (State $nested) $first @() 'RemoveAll'; throw 'Expected nested RemoveAll rejection.' }
catch { if ($_.Exception.Message -eq 'Expected nested RemoveAll rejection.') { throw } }
$malformed = $base + "# TunnelWizard BEGIN hosts bad-key`r`n"
try { $null = New-Plan (State $malformed) $first @() 'RemoveAll'; throw 'Expected malformed marker rejection.' }
catch { if ($_.Exception.Message -eq 'Expected malformed marker rejection.') { throw } }
$invalid = $base + "# TunnelWizard BEGIN hosts $($first.Label) $($first.Key)`r`n" +
    "0.0.0.1 pmx-one`r`n# TunnelWizard END hosts $($first.Label) $($first.Key)`r`n"
try { $null = New-Plan (State $invalid) $first $entry 'Sync'; throw 'Expected invalid payload rejection.' }
catch { if ($_.Exception.Message -eq 'Expected invalid payload rejection.') { throw } }
try { $null = New-Plan (State $invalid) $first @() 'RemoveAll'; throw 'Expected invalid RemoveAll payload rejection.' }
catch { if ($_.Exception.Message -eq 'Expected invalid RemoveAll payload rejection.') { throw } }

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
