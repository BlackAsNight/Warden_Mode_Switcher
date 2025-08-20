param(
    [Parameter(Mandatory=$false)]
    [string]$SavePath,

    # If not provided, you'll be prompted: true (enable) or false (disable)
    [ValidateSet('true','false')]
    [string]$Desired,

    # Write full block (inventory/sprint) like the Steam example; default is minimal
    [switch]$FullBlock,

    # If set, recreate/normalize the WardenMode block to minimal content
    [switch]$Clean,

    # Safer-than-minimal compatibility block (adds InventoryView true and empty GuardSquad)
    [switch]$CompatBlock,

    # Hybrid mode: keep inventory/UI and AvatarControl, but force Game-level WardenMode=false to preserve free cam/unlimited zoom
    [switch]$HybridZoom,

    # Experimental: when enabling, keep inventory but force AvatarControl off (to test if free cam requires AvatarControl=false)
    [switch]$HybridAvatarOff,

    # Experimental: when enabling, keep inventory injected but force WardenMode.IsActive=false post-normalization
    [switch]$HybridIsActiveOff,

    # Experimental: when enabling, keep Inventory block but force InventoryView=false (tests if zoom gate ties to InventoryView)
    [switch]$HybridInventoryViewOff,

    # Keep at most this many timestamped backups per prison file
    [int]$MaxBackups = 3,

    # Do not modify AvatarControl near the Warden's Timer line
    [switch]$NoAvatar,

    [switch]$WhatIf
    ,
    # If set, only offer restore-from-backup UI and exit
    [switch]$RestoreOnly
)

function Find-LatestPrisonSave {
    $candidates = @()
    $defaultDirs = @(
        (Join-Path $env:USERPROFILE 'AppData\Local\Introversion\Prison Architect\saves'),
        (Join-Path $env:USERPROFILE 'AppData\LocalLow\Introversion\Prison Architect\saves'),
        (Join-Path $env:USERPROFILE 'Documents\Prison Architect\saves')
    )
    foreach ($dir in $defaultDirs) {
        if (Test-Path $dir) {
            $candidates += Get-ChildItem -Path $dir -Filter '*.prison' -File -Recurse -ErrorAction SilentlyContinue
        }
    }
    if (-not $candidates) { return $null }
    return $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

if (-not $SavePath) {
    $latest = Find-LatestPrisonSave
    if (-not $latest) {
        Write-Error 'No .prison saves found. Specify -SavePath explicitly.'
        exit 1
    }
    $SavePath = $latest.FullName
}

if (-not (Test-Path $SavePath)) {
    Write-Error "Save not found: $SavePath"
    exit 1
}

# Initialize logging (after SavePath is known)
$logDir = Split-Path -Parent $SavePath
if (-not $logDir) { $logDir = '.' }
$LogFile = Join-Path $logDir 'wardenmode.log'
function Log($msg) {
    try { Add-Content -LiteralPath $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}
Log '---'
Log ("Start toggle for: {0}" -f $SavePath)
Log ("Args: Desired={0} FullBlock={1} Compat={2} Clean={3} HybridZoom={4} HybridAvatarOff={5} HybridIsActiveOff={6} HybridInventoryViewOff={7} NoAvatar={8} WhatIf={9}" -f $Desired, $FullBlock.IsPresent, $CompatBlock.IsPresent, $Clean.IsPresent, $HybridZoom.IsPresent, $HybridAvatarOff.IsPresent, $HybridIsActiveOff.IsPresent, $HybridInventoryViewOff.IsPresent, $NoAvatar.IsPresent, $WhatIf.IsPresent)

Write-Host "Target save:" $SavePath

# Read as text
$text = Get-Content -LiteralPath $SavePath -Raw -ErrorAction Stop

# Ask desired state if not provided (Y/N)
if (-not $Desired) {
    while ($true) {
        $yn = Read-Host 'Enable warden mode? Y/N'
        if ($yn -match '^(?i)Y(es)?$') { $Desired = 'true'; break }
        if ($yn -match '^(?i)N(o)?$') { $Desired = 'false'; break }
        Write-Host 'Please enter Y or N.'
    }
}
Log ("Desired resolved: {0}" -f $Desired)

# Safe defaults: if enabling and user didn't specify -FullBlock/-CompatBlock/-Clean, prefer Compat
$preferCompat = ($Desired -eq 'true' -and -not $FullBlock.IsPresent -and -not $CompatBlock.IsPresent -and -not $Clean.IsPresent)
if ($preferCompat) { Write-Host 'Defaulting to CompatBlock (safer than minimal) for enable.'; $CompatBlock = $true }

# Removed auto-default of -NoAvatar on enable to ensure AvatarControl is set.

# Implement Steam method: ensure AvatarControl under Warden entity and a BEGIN WardenMode block with proper Ids
function Get-WardenContext {
    param([string[]]$Lines)
    # Find 'Type Warden' line
    $typeIdx = $null
    for ($i=0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^(?i)\s*Type\s+Warden\b') { $typeIdx = $i; break }
    }
    if (-not $typeIdx) { return $null }
    # Find Id.i and Id.u above within 50 lines
    $idI = $null; $idU = $null; $idIIdx=$null; $idUIdx=$null
    for ($j=[Math]::Max(0,$typeIdx-50); $j -lt $typeIdx; $j++) {
        if (-not $idI -and $Lines[$j] -match '^(?i)\s*Id\.i\s+([0-9]+)\b') { $idI = $Matches[1]; $idIIdx=$j }
        if (-not $idU -and $Lines[$j] -match '^(?i)\s*Id\.u\s+([0-9]+)\b') { $idU = $Matches[1]; $idUIdx=$j }
    }
    # Find Timer below within 50 lines
    $timerIdx = $null
    for ($k=$typeIdx; $k -lt [Math]::Min($Lines.Count, $typeIdx+50); $k++) {
        if ($Lines[$k] -match '^(?i)\s*Timer\s+') { $timerIdx = $k; break }
    }
    return [pscustomobject]@{ TypeIdx=$typeIdx; IdI=$idI; IdU=$idU; TimerIdx=$timerIdx }
}

function Ensure-AvatarControl {
    param([string[]]$Lines, [int]$TimerIdx, [bool]$Enable)
    if ($TimerIdx -lt 0) { return $Lines }
    # Look in next few lines for AvatarControl
    $foundIdx = $null
    for ($t=$TimerIdx+1; $t -le [Math]::Min($Lines.Count-1,$TimerIdx+5); $t++) {
        if ($Lines[$t] -match '^(?i)\s*AvatarControl\b') { $foundIdx=$t; break }
        if ($Lines[$t] -match '^(?i)\s*Id\.i\b|^\s*BEGIN\b|^\s*END\b|^\s*Type\b') { break }
    }
    if ($Enable) {
        if ($foundIdx -ne $null) {
            # Ensure value true
            $Lines[$foundIdx] = '    AvatarControl           true'
            Write-Host "Ensured AvatarControl true near Warden Timer."
            return $Lines
        } else {
            $insertLine = '    AvatarControl           true'
            $new = @()
            $new += $Lines[0..$TimerIdx]
            if ($TimerIdx -lt $Lines.Count-1) { $new += $insertLine; $new += $Lines[($TimerIdx+1)..($Lines.Count-1)] } else { $new += $insertLine }
            Write-Host "Inserted AvatarControl under Warden Timer line."
            return $new
        }
    } else {
        # Disable: remove the line if present
        if ($foundIdx -ne $null) {
            $new = @()
            if ($foundIdx -gt 0) { $new += $Lines[0..($foundIdx-1)] }
            if ($foundIdx -lt $Lines.Count-1) { $new += $Lines[($foundIdx+1)..($Lines.Count-1)] }
            Write-Host "Removed AvatarControl line."
            return $new
        }
        return $Lines
    }
}

function Ensure-WardenModeBlock {
    param([string]$FullText, [string]$IdI, [string]$IdU, [string]$IsActive, [bool]$WriteFull, [bool]$CleanExisting, [bool]$Compat)
    # Build the desired canonical block
    $blockLines = @()
    if ($WriteFull) {
        $blockLines = @(
            'BEGIN WardenMode',
            ('    IsActive             ' + $IsActive),
            ('    WardenId.i           ' + $IdI),
            ('    WardenId.u           ' + $IdU),
            '    InventoryView        true',
            '    BEGIN Inventory',
            '        SlotEquipped         -1',
            '        BEGIN InventorySlots Size 2  "[i 0]" 29  "[i 1]" 0  END',
            '        BEGIN InventoryAmmo Size 2  "[i 0]" -1  "[i 1]" -1  END',
            '    END',
            '    BEGIN GuardSquad',
            '    END',
            'END'
        )
    } elseif ($CleanExisting) {
        $blockLines = @(
            'BEGIN WardenMode',
            ('    IsActive             ' + $IsActive),
            ('    WardenId.i           ' + $IdI),
            ('    WardenId.u           ' + $IdU),
            'END'
        )
    } elseif ($Compat) {
        $blockLines = @(
            'BEGIN WardenMode',
            ('    IsActive             ' + $IsActive),
            ('    WardenId.i           ' + $IdI),
            ('    WardenId.u           ' + $IdU),
            '    InventoryView        true',
            '    BEGIN GuardSquad',
            '    END',
            'END'
        )
    } else {
        $blockLines = @(
            'BEGIN WardenMode',
            ('    IsActive             ' + $IsActive),
            ('    WardenId.i           ' + $IdI),
            ('    WardenId.u           ' + $IdU),
            'END'
        )
    }

    $newBlock = ($blockLines -join "`r`n") + "`r`n"

    $pattern = '(?ims)(?i)^\s*BEGIN\s+WardenMode\b.*?^\s*END\s*$'
    $matches = [regex]::Matches($FullText, $pattern)
    if ($matches.Count -gt 0) {
        $start = $matches[0].Index
        $last = $matches[$matches.Count-1]
        $end = $last.Index + $last.Length
        $prefix = $FullText.Substring(0, $start)
        $suffix = $FullText.Substring($end)
        Write-Host ("Normalized {0} WardenMode block(s) into one." -f $matches.Count)
        return ($prefix + $newBlock + $suffix)
    } else {
        # Append new minimal/compat/full block
        $trimmed = $FullText.TrimEnd()
        $newBlock = ($blockLines -join "`r`n")
        $result = if ($trimmed -match '\\S') { $trimmed + "`r`n" + $newBlock } else { $newBlock }
        Write-Host 'Appended WardenMode block at EOF.'
        return $result
    }
}

if ($WhatIf) { Write-Host 'WhatIf: no changes written.'; exit 0 }

function Set-InGameBlockFlag {
    param(
        [string]$fullText,
        [string]$keyName,
        [string]$value
    )
    $lines = $fullText -split "\r?\n"
    $beginIdx = ($lines | Select-String -Pattern '^(?i)\s*BEGIN\s+Game\b' -SimpleMatch:$false).LineNumber
    if ($beginIdx) {
        $i0 = [int]$beginIdx - 1
        # find END after BEGIN Game
        $endIdx = $null
        for ($i = $i0 + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^(?i)\s*END\s*$') { $endIdx = $i; break }
        }
        if (-not $endIdx) { $endIdx = $lines.Count - 1 }
        # remove duplicate occurrences of the key within the block (keep none for now; we'll insert/update one below)
        $rangeBefore = $lines[0..$i0]
        $rangeInside = $lines[($i0+1)..$endIdx]
        $rangeAfter = if ($endIdx -lt $lines.Count-1) { $lines[($endIdx+1)..($lines.Count-1)] } else { @() }
        $rxKey = [regex]('^(?i)\s*' + [regex]::Escape($keyName) + '\s+(true|false)\s*$')
        $rangeInside = @($rangeInside | Where-Object { -not $rxKey.IsMatch($_) })
        $lines = $rangeBefore + $rangeInside + $rangeAfter
        # recompute end index after removal
        $beginIdx2 = ($lines | Select-String -Pattern '^(?i)\s*BEGIN\s+Game\b' -SimpleMatch:$false).LineNumber
        $i0 = [int]$beginIdx2 - 1
        $endIdx = $null
        for ($i = $i0 + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^(?i)\s*END\s*$') { $endIdx = $i; break }
        }
        if (-not $endIdx) { $endIdx = $lines.Count - 1 }
        # search for key within block (should be absent after cleanup)
        $rxLine = [regex]("(?im)^(\\s*" + [regex]::Escape($keyName) + "\\s+)(true|false)(\\s*)$")
        $replaced = $false
        for ($i = $i0 + 1; $i -lt $endIdx; $i++) {
            $m = $rxLine.Match($lines[$i])
            if ($m.Success) {
                $lines[$i] = $m.Groups[1].Value + $value + $m.Groups[3].Value
                $replaced = $true
                break
            }
        }
        if (-not $replaced) {
            $lines = $lines[0..$i0] + ("    $keyName $value") + $lines[($i0+1)..($lines.Count-1)]
            Write-Host "Inserted $keyName inside BEGIN Game block."
        } else {
            Write-Host "Updated $keyName inside BEGIN Game block."
        }
        return ($lines -join "`r`n")
    }
    return $null
}

# Apply Steam method edits
$lines = $text -split "\r?\n"
$ctx = Get-WardenContext -Lines $lines
if (-not $ctx) { Write-Error 'Could not find Warden entity (Type Warden).'; exit 2 }
if (-not $ctx.IdI -or -not $ctx.IdU) { Write-Error 'Could not extract Warden Id.i / Id.u near Warden entity.'; exit 3 }
if ($ctx.TimerIdx -lt 0) { Write-Error 'Could not locate Timer line within Warden entity.'; exit 4 }
Log ("Context: Warden Id.i={0} Id.u={1} TimerIdx={2}" -f $ctx.IdI, $ctx.IdU, $ctx.TimerIdx)

# Ensure AvatarControl line (add on enable, remove on disable) unless -NoAvatar. In HybridAvatarOff, force removal on enable for testing.
if ($NoAvatar) {
    Write-Host 'Skipping AvatarControl changes due to -NoAvatar.'
    $lines2 = $lines
} else {
    $enable = ($Desired -eq 'true')
    if ($enable -and $HybridAvatarOff.IsPresent) {
        Write-Host 'HybridAvatarOff: forcing AvatarControl off while enabling (experiment).'
        Log 'HybridAvatarOff active: forcing AvatarControl=false while enabling.'
        $enable = $false
    }
    $lines2 = Ensure-AvatarControl -Lines $lines -TimerIdx $ctx.TimerIdx -Enable:$enable
}
$text2 = ($lines2 -join "`r`n")
Write-Host 'Normalizing WardenMode block...'

# Ensure/Update WardenMode block with current ids and desired IsActive
$final = Ensure-WardenModeBlock -FullText $text2 -IdI $ctx.IdI -IdU $ctx.IdU -IsActive $Desired -WriteFull:$FullBlock.IsPresent -CleanExisting:$Clean.IsPresent -Compat:$CompatBlock.IsPresent
if ($Desired -eq 'true' -and $HybridIsActiveOff.IsPresent) {
    try {
        $wm3 = [regex]::Match($final, '(?ims)^\s*BEGIN\s+WardenMode\b.*?^\s*END\s*$')
        if ($wm3.Success) {
            $blk2 = $wm3.Value
            if ($blk2 -match '(?im)^\s*IsActive\s+\w+') {
                $blk2 = [regex]::Replace($blk2, '(?im)^(\s*IsActive\s+)\w+(\s*)$', '${1}false${2}', 1)
            } else {
                $blk2 = [regex]::Replace($blk2, '(?im)^(\s*BEGIN\s+WardenMode\s*\r?\n)', '${1}    IsActive             false`r`n', 1)
            }
            $final = $final.Substring(0, $wm3.Index) + $blk2 + $final.Substring($wm3.Index + $wm3.Length)
            Write-Host 'HybridIsActiveOff: forced WardenMode.IsActive=false post-normalization (experiment).'
            Log 'HybridIsActiveOff active: IsActive=false after normalization.'
        }
    } catch {}
}
Write-Host 'Normalization done.'

# Verify resulting states for debugging
try {
    $wmv = [regex]::Match($final, '(?ims)^\s*BEGIN\s+WardenMode\b.*?^\s*END\s*$')
    if ($wmv.Success) {
        $isActiveVal = 'UNKNOWN'
        $ma = [regex]::Match($wmv.Value, '(?im)^\s*IsActive\s+(true|false)\b')
        if ($ma.Success) { $isActiveVal = $ma.Groups[1].Value }
        Write-Host ("Verify: WardenMode.IsActive={0}" -f $isActiveVal)
    } else {
        Write-Host 'Verify: No WardenMode block found after normalization.'
    }
    $hasAvatar = ($final -match '(?im)^\s*AvatarControl\s+true\b')
    $avatarVal = if ($hasAvatar) { 'true' } else { 'false' }
    Write-Host ("Verify: AvatarControl={0}" -f $avatarVal)
} catch { }
Log ("Verify: WardenMode.IsActive={0}" -f $isActiveVal)
Log ("Verify: AvatarControl={0}" -f $avatarVal)

# Verify inventory state and log
try {
    $hasInvView = ($final -match '(?im)^\s*InventoryView\s+true\b')
    $hasInvBlock = ($final -match '(?ims)^\s*BEGIN\s+Inventory\b.*?^\s*END\s*$')
    $invViewVal = if ($hasInvView) { 'true' } else { 'false' }
    $invBlockVal = if ($hasInvBlock) { 'true' } else { 'false' }
    Write-Host ("Verify: InventoryView={0}" -f $invViewVal)
    Write-Host ("Verify: InventoryBlock={0}" -f $invBlockVal)
    Log ("Verify: InventoryView={0}" -f $invViewVal)
    Log ("Verify: InventoryBlock={0}" -f $invBlockVal)
} catch { }

try {
    $wm_dump = [regex]::Match($final, '(?ims)^\s*BEGIN\s+WardenMode\b.*?^\s*END\s*$')
    if ($wm_dump.Success) {
        Log 'WardenMode block (first 25 shown):'
        $snippet = ($wm_dump.Value -split "\r?\n")[0..([Math]::Min(24, ($wm_dump.Value -split "\r?\n").Count-1))] -join "`n"
        Log $snippet
    } else {
        Log 'No WardenMode block found to dump.'
    }
} catch {
    Log 'Failed to dump WardenMode block.'
}

# Prompt for Permadeath when enabling (Y/N), default to current value if present otherwise false
if ($Desired -eq 'true') {
    try {
        $wm = [regex]::Match($final, '(?ims)^\s*BEGIN\s+WardenMode\b.*?^\s*END\s*$')
        if ($wm.Success) {
            $block = $wm.Value
            $cur = 'false'
            $m2 = [regex]::Match($block, '(?im)^\s*Permadeath\s+(true|false)\b')
            if ($m2.Success) { $cur = $m2.Groups[1].Value }
            $resp = $null
            while ($null -eq $resp) {
                $yn = Read-Host ("Enable permadeath? Y/N [default: {0}]" -f $cur)
                if ([string]::IsNullOrWhiteSpace($yn)) { $resp = $cur; break }
                if ($yn -match '^(?i)Y(es)?$') { $resp = 'true'; break }
                if ($yn -match '^(?i)N(o)?$') { $resp = 'false'; break }
                Write-Host 'Please enter Y or N.'
            }
            # Apply value (replace or insert after IsActive)
            if ($block -match '(?im)^\s*Permadeath\s+(true|false)\b') {
                $block = [regex]::Replace($block, '(?im)^(\s*Permadeath\s+)(true|false)(\s*)$', '${1}' + $resp.ToLower() + '${3}', 1)
            } else {
                $block = [regex]::Replace($block, '(?im)^(\s*IsActive\s+\w+\s*\r?\n)', '${1}    Permadeath           ' + $resp.ToLower() + "`r`n", 1)
            }
            $final = $final.Substring(0, $wm.Index) + $block + $final.Substring($wm.Index + $wm.Length)
            Write-Host ("Set WardenMode.Permadeath to {0}." -f $resp.ToLower())
            Log ("Permadeath set to {0}" -f $resp.ToLower())
        }
    } catch {
        Write-Warning "Failed to set Permadeath: $($_.Exception.Message)"
        Log ("Failed to set Permadeath: {0}" -f $_.Exception.Message)
    }
}

# Backups/Restore setup
$pngPath = [System.IO.Path]::ChangeExtension($SavePath, '.png')
$saveDir = Split-Path -Parent $SavePath
$saveBase = [System.IO.Path]::GetFileNameWithoutExtension($SavePath)
$backupDir = Join-Path $saveDir 'Backups'
if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }

if ($RestoreOnly) {
    # Offer restore from backup and exit
    try {
        $existing = Get-ChildItem -LiteralPath $backupDir -Filter ("{0}-*.prison" -f $saveBase) | Sort-Object LastWriteTime -Descending
        if ($existing.Count -gt 0) {
            Write-Host 'Select a backup to restore:'
            $list = $existing | Select-Object -First 3
            for ($i=0; $i -lt $list.Count; $i++) {
                $f = $list[$i]
                $stamp = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                Write-Host ("  {0}) {1}  [{2}]" -f ($i+1), (Split-Path -Leaf $f.FullName), $stamp)
            }
            Write-Host '  0) Cancel'
            $sel = Read-Host 'Enter number'
            if ($sel -match '^[0-3]$') {
                $n = [int]$sel
                if ($n -ge 1 -and $n -le $list.Count) {
                    $chosen = $list[$n-1]
                    $peerPng = [System.IO.Path]::ChangeExtension($chosen.FullName, '.png')
                    Copy-Item -LiteralPath $chosen.FullName -Destination $SavePath -Force
                    if (Test-Path -LiteralPath $peerPng) { Copy-Item -LiteralPath $peerPng -Destination $pngPath -Force }
                    Write-Host ("Restored backup: {0}" -f (Split-Path -Leaf $chosen.FullName))
                    Log ("Restored backup {0}" -f $chosen.FullName)
                    Write-Host 'Done. Open/reload the save in-game to use this backup.'
                }
            }
        } else {
            Write-Host 'No backups found to restore.'
        }
    } catch { Write-Warning ("Backup restore prompt failed: {0}" -f $_.Exception.Message) }
    exit 0
}

if ($WhatIf) { Write-Host 'WhatIf: no changes written.'; exit 0 }

$tempNew = "$SavePath.new"
Log 'Writing .new file...'
[System.IO.File]::WriteAllText($tempNew, $final, (New-Object System.Text.UTF8Encoding($false)))

# Retry helper
function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [int]$Retries = 5,
        [int]$DelayMs = 300,
        [string]$Description = 'operation'
    )
    for ($i=1; $i -le $Retries; $i++) {
        try { & $Action; return $true } catch {
            if ($i -ge $Retries) { Write-Warning ("{0} failed after {1} attempts: {2}" -f $Description, $Retries, $_.Exception.Message); return $false }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

# Pre-patch backups (retain last 3)
try {
    $saveDir = Split-Path -Parent $SavePath
    $saveBase = [System.IO.Path]::GetFileNameWithoutExtension($SavePath)
    $backupDir = Join-Path $saveDir 'Backups'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $bkPrison = Join-Path $backupDir ("{0}-{1}.prison" -f $saveBase, $ts)
    $bkPng    = Join-Path $backupDir ("{0}-{1}.png"    -f $saveBase, $ts)
    Write-Host ("Creating backup set -> {0}" -f (Split-Path -Leaf $bkPrison))
    Log ("Backup target: {0}" -f $bkPrison)
    Copy-Item -LiteralPath $SavePath -Destination $bkPrison -Force
    if (Test-Path -LiteralPath $pngPath) { Copy-Item -LiteralPath $pngPath -Destination $bkPng -Force }
    # Prune older backups beyond MaxBackups (based on .prison files)
    $existing = Get-ChildItem -LiteralPath $backupDir -Filter ("{0}-*.prison" -f $saveBase) | Sort-Object LastWriteTime -Descending
    $keep = if ($MaxBackups -ge 1) { $MaxBackups } else { 1 }
    if ($existing.Count -gt $keep) {
        $toDelete = $existing[$keep..($existing.Count-1)]
        $n = 0
        foreach ($f in $toDelete) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $pngPeer = [System.IO.Path]::ChangeExtension($f.FullName, '.png')
                if (Test-Path -LiteralPath $pngPeer) { Remove-Item -LiteralPath $pngPeer -Force }
                $n++
            } catch { Log ("Prune failed for {0}: {1}" -f $f.FullName, $_.Exception.Message) }
        }
        if ($n -gt 0) { Write-Host ("Pruned {0} old backup(s)." -f $n) }
    }
} catch {
    Write-Warning ("Backup step encountered an error: {0}" -f $_.Exception.Message)
}

try {
    # Atomic replace to minimize race with the game reading the file
    $swapBak = "$SavePath.bak"
    if (-not (Invoke-WithRetry -Description 'Atomic replace save' -Action { [System.IO.File]::Replace($tempNew, $SavePath, $swapBak) })) { throw "Replace failed" }
    Log 'Replaced original file atomically.'
    if (Test-Path -LiteralPath $swapBak) { Remove-Item -LiteralPath $swapBak -Force }
} catch {
    Write-Warning "Safe swap failed: $($_.Exception.Message). Falling back to direct write."
    [System.IO.File]::WriteAllText($SavePath, $final, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path $tempNew) { Remove-Item -LiteralPath $tempNew -Force }
    Log ("Safe swap failed: {0} (used direct write)" -f $_.Exception.Message)
}

# Silently refresh PNG thumbnail timestamp (some builds require this); no console messages
if (Test-Path -LiteralPath $pngPath) {
    try {
        $tempPng = "$pngPath.new"
        Log 'Refreshing PNG thumbnail timestamp...'
        Copy-Item -LiteralPath $pngPath -Destination $tempPng -Force
        $pngSwapBak = "$pngPath.bak"
        if (-not (Invoke-WithRetry -Description 'Atomic replace png' -Action { [System.IO.File]::Replace($tempPng, $pngPath, $pngSwapBak) })) { throw "PNG replace failed" }
        if (Test-Path -LiteralPath $pngSwapBak) { Remove-Item -LiteralPath $pngSwapBak -Force }
        Log 'PNG thumbnail refresh complete (atomic replace).'
    } catch {
        Log ("PNG refresh failed: {0}" -f $_.Exception.Message)
        if (Test-Path "$pngPath.new") { Remove-Item -LiteralPath "$pngPath.new" -Force }
    }
}

# Backups removed by user request

Write-Host 'Done. Restart/Reload the save in-game to see the change.'
Log 'Done.'
