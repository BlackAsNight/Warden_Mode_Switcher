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
    if (-not $candidates) { return @() }
    # Exclude our backup copies (in Backups folders or timestamp-suffixed names)
    $candidates = $candidates | Where-Object {
        $_.FullName -notmatch '\\Backups\\' -and (Split-Path -Leaf $_.FullName) -notmatch '-\d{8}_\d{6}\.prison$'
    }
    return $candidates | Sort-Object LastWriteTime -Descending
}

if (-not $SavePath) {
    $all = Find-LatestPrisonSave
    if (-not $all -or $all.Count -eq 0) {
        Write-Error 'No .prison saves found. Specify -SavePath explicitly.'
        exit 1
    }
    $list = $all | Select-Object -First 5
    Write-Host 'Select a save to modify:'
    for ($i=0; $i -lt $list.Count; $i++) {
        $f = $list[$i]
        $stamp = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        Write-Host ("  {0}) {1}  [{2}]" -f ($i+1), (Split-Path -Leaf $f.FullName), $stamp)
    }
    Write-Host '  0) Cancel'
    while ($true) {
        $sel = Read-Host 'Enter number'
        if ($sel -match '^[0-9]+$') {
            $n = [int]$sel
            if ($n -eq 0) { Write-Host 'Canceled by user.'; exit 0 }
            if ($n -ge 1 -and $n -le $list.Count) { $SavePath = $list[$n-1].FullName; break }
        }
        Write-Host ("Invalid selection. Please choose 0-{0}." -f $list.Count)
    }
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
    param(
        [string[]]$Lines,
        [switch]$CompatBlock
    )

    # Find the Warden entity and capture its block boundaries
    $wardenTypeMatch = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*Type\s+Warden\b') { $wardenTypeMatch = $i; break }
    }
    if ($wardenTypeMatch -eq $null) { return $null }

    $wardenBegin = $null
    $wardenEnd   = $null

    # Walk backward to the nearest BEGIN
    for ($j = $wardenTypeMatch; $j -ge 0; $j--) {
        if ($Lines[$j] -match '^\s*BEGIN\b') { $wardenBegin = $j; break }
    }
    # Walk forward from BEGIN to the matching END
    if ($wardenBegin -ne $null) {
        for ($k = $wardenBegin; $k -lt $Lines.Count; $k++) {
            if ($Lines[$k] -match '^\s*END\b') { $wardenEnd = $k; break }
        }
    }

    # Defaults
    $idI = $null
    $idU = $null
    $timerIdx = $null
    $posX = $null
    $posY = $null

    # Extract details from within the Warden block
    if ($wardenBegin -ne $null -and $wardenEnd -ne $null) {
        for ($i = $wardenBegin; $i -le $wardenEnd; $i++) {
            $line = $Lines[$i]
            if ($idI -eq $null -and $line -match 'Id\.i\s+([0-9]+)') { $idI = $Matches[1] }
            if ($idU -eq $null -and $line -match 'Id\.u\s+([0-9]+)') { $idU = $Matches[1] }
            if ($timerIdx -eq $null -and $line -match '^\s*Timer\s+') { $timerIdx = $i }
            if ($posX -eq $null -and $line -match 'Pos\.x\s+([+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)') { $posX = [double]$Matches[1] }
            if ($posY -eq $null -and $line -match 'Pos\.y\s+([+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)') { $posY = [double]$Matches[1] }
        }
    }

    Write-Verbose ("Get-WardenContext: Id.i={0} Id.u={1} TimerIdx={2} Pos=({3},{4}) Begin={5} End={6}" -f $idI,$idU,$timerIdx,$posX,$posY,$wardenBegin,$wardenEnd)

    return [pscustomobject]@{
        IdI      = $idI
        IdU      = $idU
        TimerIdx = $timerIdx
        PosX     = $posX
        PosY     = $posY
        BeginIdx = $wardenBegin
        EndIdx   = $wardenEnd
    }
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

function Remove-AvatarControlOutsideWarden {
    param(
        [string[]]$Lines,
        [int]$BeginIdx,
        [int]$EndIdx
    )

    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $isAvatarLine = ($Lines[$i] -match '^(?i)\s*AvatarControl\b')
        $inWarden = ($BeginIdx -ne $null -and $EndIdx -ne $null -and $i -ge $BeginIdx -and $i -le $EndIdx)
        if ($isAvatarLine -and -not $inWarden) {
            # Drop AvatarControl lines that are outside the Warden block
            continue
        }
        $out.Add($Lines[$i])
    }
    if ($out.Count -ne $Lines.Count) {
        Write-Host 'Removed AvatarControl lines outside the Warden block.'
        Log 'Pruned AvatarControl outside Warden block.'
    }
    return ,$out.ToArray()
}

function Ensure-WardenModeBlock {
    param([string]$FullText, [string]$IdI, [string]$IdU, [string]$IsActive, [bool]$WriteFull, [bool]$CleanExisting, [bool]$Compat)

    function New-WardenModeBlock([string]$ii,[string]$uu,[string]$active,[bool]$full,[bool]$compat,[string]$existingInventory){
        # Default clipboard inventory for first-time warden mode
        $defaultInventory = @(
            '    BEGIN Inventory',
            '        SlotEquipped         0',
            '        BEGIN InventorySlots Size 2  "[i 0]" 29  "[i 1]" 0  END',
            '        BEGIN InventoryAmmo Size 2  "[i 0]" -1  "[i 1]" -1  END',
            '    END'
        ) -join "`r`n"

        if ($full) {
            $inventoryBlock = if ($existingInventory) { $existingInventory } else { $defaultInventory }
            return @(
                'BEGIN WardenMode',
                ('    IsActive             ' + $active),
                ('    WardenId.i           ' + $ii),
                ('    WardenId.u           ' + $uu),
                '    InventoryView        true',
                $inventoryBlock,
                '    BEGIN GuardSquad',
                '    END',
                'END'
            ) -join "`r`n"
        }
        if ($compat) {
            $inventoryBlock = if ($existingInventory) { $existingInventory } else { $defaultInventory }
            return @(
                'BEGIN WardenMode',
                ('    IsActive             ' + $active),
                ('    WardenId.i           ' + $ii),
                ('    WardenId.u           ' + $uu),
                '    InventoryView        true',
                $inventoryBlock,
                '    BEGIN GuardSquad',
                '    END',
                'END'
            ) -join "`r`n"
        }
        return @(
            'BEGIN WardenMode',
            ('    IsActive             ' + $active),
            ('    WardenId.i           ' + $ii),
            ('    WardenId.u           ' + $uu),
            'END'
        ) -join "`r`n"
    }

    $lines = $FullText -split "`r`n"
    $beginPattern = '^\s*BEGIN\s+WardenMode\b'
    $endPattern = '^\s*END\s*$'

    $blockRanges = @()
    $depth = 0
    $startIdx = -1

    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match $beginPattern) {
            if ($depth -eq 0) { $startIdx = $i }
            $depth++
        } elseif ($lines[$i] -match $endPattern) {
            if ($depth -gt 0) {
                $depth--
                if ($depth -eq 0) {
                    $blockRanges += @{ Start = $startIdx; End = $i }
                    $startIdx = -1
                }
            }
        }
    }

    if ($blockRanges.Count -gt 0) {
        $firstBlockRange = $blockRanges[0]
        $prefixLines = $lines[0..($firstBlockRange.Start - 1)]
        
        $suffixLines = if ($firstBlockRange.End + 1 -lt $lines.Length) {
            $lines[($firstBlockRange.End + 1)..$($lines.Length - 1)]
        } else { @() }

        # Extract existing inventory if present
        $existingInventory = $null
        $existingBlock = $lines[$firstBlockRange.Start..$firstBlockRange.End] -join "`r`n"
        $inventoryMatch = [regex]::Match($existingBlock, '(?ims)^\s*BEGIN\s+Inventory\b.*?^\s*END\s*$')
        if ($inventoryMatch.Success) {
            $existingInventory = $inventoryMatch.Value
            Write-Host "Found existing inventory block - preserving for persistent inventory."
            Log "Preserving existing inventory block for persistence."
        }

        # For disable mode, preserve all existing data and only set IsActive=false
        if ($IsActive -eq 'false' -and $existingBlock -match 'IsActive\s+true') {
            $preservedBlock = [regex]::Replace($existingBlock, '(?im)^(\s*IsActive\s+)true(\s*)$', '${1}false${2}', 1)
            Write-Host "Disabled warden mode while preserving all existing data."
            Log "Preserved warden data, only set IsActive=false."
            return ($prefixLines + $preservedBlock + $suffixLines) -join "`r`n"
        }

        $newBlockContent = (New-WardenModeBlock $IdI $IdU $IsActive $WriteFull $Compat $existingInventory)
        
        Write-Host "Replaced existing WardenMode block with a new one."
        return ($prefixLines + $newBlockContent + $suffixLines) -join "`r`n"
    }

    # No existing block: append a new one
    $trimmed = $FullText.TrimEnd()
    $newBlock = (New-WardenModeBlock $IdI $IdU $IsActive $WriteFull $Compat $null)
    $result = if ($trimmed -match '\S') { $trimmed + "`r`n" + $newBlock } else { $newBlock }
    Write-Host 'Appended new WardenMode block at EOF.'
    return $result
}

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

# Ensure only the Warden has AvatarControl=true
$ctx2 = Get-WardenContext -Lines $lines2
if ($ctx2 -and $ctx2.BeginIdx -ne $null -and $ctx2.EndIdx -ne $null) {
    $lines3 = Remove-AvatarControlOutsideWarden -Lines $lines2 -BeginIdx $ctx2.BeginIdx -EndIdx $ctx2.EndIdx
} else {
    $lines3 = $lines2
}

Write-Host 'Normalizing WardenMode block...'
$final = Ensure-WardenModeBlock -FullText ($lines3 -join "`r`n") -IdI $ctx.IdI -IdU $ctx.IdU -IsActive $Desired -WriteFull:$FullBlock.IsPresent -CleanExisting:$Clean.IsPresent -Compat:$CompatBlock.IsPresent
if ($final -notmatch "`r`n$") { $final += "`r`n" }

# Safety: never write a drastically smaller file when enabling
if ($Desired -eq 'true' -and ($final.Length -lt [math]::Round($text.Length * 0.75))) {
    throw "Safety abort: New content is unexpectedly smaller than original (original=$($text.Length), new=$($final.Length)). Not writing to disk."
}

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

# Exit if WhatIf
if ($WhatIf.IsPresent) {
    Write-Host "WhatIf: Would write changes to $SavePath"
    return
}

# Write to temp file first
$tempNew = "$SavePath.new"
[System.IO.File]::WriteAllText($tempNew, $final, (New-Object System.Text.UTF8Encoding($false)))
Log 'Wrote changes to temp file.'

# Create backup directories
try {
    $saveDir = Split-Path -Parent $SavePath
    $saveBase = [System.IO.Path]::GetFileNameWithoutExtension($SavePath)
    $backupDir = Join-Path $saveDir 'Backups'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $bkPrison = Join-Path $backupDir ("{0}-{1}.prison" -f $saveBase, $ts)
    $bkPng    = Join-Path $backupDir ("{0}-{1}.png"    -f $saveBase, $ts)
    Copy-Item -LiteralPath $SavePath -Destination $bkPrison -Force
    Log ("Backup created: {0}" -f (Split-Path -Leaf $bkPrison))
    
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


# Helper: returns a list of office desk positions [{PosX,PosY}]
function Get-OfficeDeskPositions {
    param([string[]]$Lines)

    $desks = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '^\s*BEGIN\b.*\bType\s+OfficeDesk\b.*\bEND\b') {
            # Single-line block
            if ($line -match 'Pos\.x\s+([+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)') { $px = [double]$Matches[1] } else { $px = $null }
            if ($line -match 'Pos\.y\s+([+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)') { $py = [double]$Matches[1] } else { $py = $null }
            if ($px -ne $null -and $py -ne $null) {
                $desks.Add([pscustomobject]@{ PosX=$px; PosY=$py })
            }
        }
        elseif ($line -match '^\s*Type\s+OfficeDesk\b') {
            # Multi-line: capture within BEGIN..END range enclosing this line
            $begin = $null; $end = $null
            for ($b = $i; $b -ge 0; $b--) { if ($Lines[$b] -match '^\s*BEGIN\b') { $begin = $b; break } }
            if ($begin -ne $null) {
                for ($e = $begin; $e -lt $Lines.Count; $e++) { if ($Lines[$e] -match '^\s*END\b') { $end = $e; break } }
            }
            if ($begin -ne $null -and $end -ne $null) {
                $px = $null; $py = $null
                for ($k = $begin; $k -le $end; $k++) {
                    if ($px -eq $null -and $Lines[$k] -match 'Pos\.x\s+([+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)') { $px = [double]$Matches[1] }
                    if ($py -eq $null -and $Lines[$k] -match 'Pos\.y\s+([+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)') { $py = [double]$Matches[1] }
                }
                if ($px -ne $null -and $py -ne $null) {
                    $desks.Add([pscustomobject]@{ PosX=$px; PosY=$py })
                }
            }
        }
    }

    return $desks
    # ... existing code ...
}

# Helper: set or insert Warden Pos.x/Pos.y within its block
function Set-WardenPosition {
    param(
        [string[]]$Lines,
        [int]$BeginIdx,
        [int]$EndIdx,
        [double]$NewX,
        [double]$NewY
    )

    if ($BeginIdx -eq $null -or $EndIdx -eq $null -or $BeginIdx -ge $EndIdx) { return $Lines }

    $posXIdx = $null; $posYIdx = $null
    for ($i = $BeginIdx; $i -le $EndIdx; $i++) {
        if ($posXIdx -eq $null -and $Lines[$i] -match '^\s*Pos\.x\b') { $posXIdx = $i }
        if ($posYIdx -eq $null -and $Lines[$i] -match '^\s*Pos\.y\b') { $posYIdx = $i }
    }

    $fmtX = ('{0,-22} {1}' -f 'Pos.x', ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.00000}', $NewX)))
    $fmtY = ('{0,-22} {1}' -f 'Pos.y', ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.00000}', $NewY)))

    if ($posXIdx -ne $null) { $Lines[$posXIdx] = $fmtX } else { $Lines = $Lines[0..($EndIdx-1)] + @($fmtX) + $Lines[$EndIdx..($Lines.Count-1)] ; $EndIdx++ }
    if ($posYIdx -ne $null) { $Lines[$posYIdx] = $fmtY } else { $Lines = $Lines[0..($EndIdx-1)] + @($fmtY) + $Lines[$EndIdx..($Lines.Count-1)] ; $EndIdx++ }

    return $Lines
    # ... existing code ...
}

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

# Verify resulting states for debugging
$isActiveVal = 'UNKNOWN'
$avatarVal = 'false'
try {
    $wmv = [regex]::Match($final, '(?ims)^\s*BEGIN\s+WardenMode\b.*?^\s*END\s*$')
    if ($wmv.Success) {
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

# Setup backup directories early
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

# Exit if WhatIf
if ($WhatIf.IsPresent) {
    Write-Host "WhatIf: Would write changes to $SavePath"
    exit 0
}


# Position validation function
function Test-InvalidPos([double]$x,[double]$y) {
    if ($null -eq $x -or $null -eq $y) { return $true }
    if ([double]::IsNaN($x) -or [double]::IsNaN($y)) { return $true }
    # reject absurd ranges and known float-max sentinels
    if ([math]::Abs($x) -gt 100000 -or [math]::Abs($y) -gt 100000) { return $true }
    return $false
}

# Check and fix Warden position if needed
$ctx2 = Get-WardenContext -Lines $lines3 -CompatBlock:$CompatBlock
Write-Host ("Detected Warden Id.i={0} Id.u={1} Pos=({2},{3}) Block=[{4}-{5}]" -f $ctx2.IdI,$ctx2.IdU,$ctx2.PosX,$ctx2.PosY,$ctx2.BeginIdx,$ctx2.EndIdx)

$posInvalid = Test-InvalidPos $ctx2.PosX $ctx2.PosY
if ($posInvalid -and $ctx2.BeginIdx -ne $null -and $ctx2.EndIdx -ne $null) {
    Write-Warning "Warden position appears invalid. Attempting to place Warden near an OfficeDesk."
    $desks = Get-OfficeDeskPositions -Lines $lines3
    if ($desks.Count -gt 0) {
        # pick the first desk (or you can choose nearest to some heuristic)
        $target = $desks[0]
        $newX = $target.PosX + 1.0
        $newY = $target.PosY + 1.0
        Write-Host ("Relocating Warden to OfficeDesk-adjacent tile: ({0},{1})" -f $newX,$newY)
        $lines3 = Set-WardenPosition -Lines $lines3 -BeginIdx $ctx2.BeginIdx -EndIdx $ctx2.EndIdx -NewX $newX -NewY $newY
        # refresh context for logging
        $ctx2 = Get-WardenContext -Lines $lines3 -CompatBlock:$CompatBlock
        Write-Host ("New Warden Pos=({0},{1})" -f $ctx2.PosX,$ctx2.PosY)
    } else {
        Write-Warning "No OfficeDesk found to use as a safe placement. Skipping auto-fix."
    }
}

# Create timestamped backup before making changes
try {
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $bkPrison = Join-Path $backupDir ("{0}-{1}.prison" -f $saveBase, $ts)
    $bkPng    = Join-Path $backupDir ("{0}-{1}.png"    -f $saveBase, $ts)
    
    Copy-Item -LiteralPath $SavePath -Destination $bkPrison -Force
    Log ("Backup created: {0}" -f (Split-Path -Leaf $bkPrison))
    
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

# Write changes to save file
try {
    # Create an immediate backup before writing
    $immediateBackup = "$SavePath.immediate.bak"
    Copy-Item -LiteralPath $SavePath -Destination $immediateBackup -Force
    Log 'Created immediate backup before writing changes.'
    
    # Use direct write instead of atomic replacement
    [System.IO.File]::WriteAllText($SavePath, $final, (New-Object System.Text.UTF8Encoding($false)))
    Log 'Wrote changes directly to save file.'
    
    # Clean up immediate backup on success
    if (Test-Path -LiteralPath $immediateBackup) { Remove-Item -LiteralPath $immediateBackup -Force }
} catch {
    Write-Warning "Save file write failed: $($_.Exception.Message). Attempting to restore from backup."
    Log "Save file write failed: $($_.Exception.Message)"
    
    # Try to restore from immediate backup if write fails
    if (Test-Path -LiteralPath $immediateBackup) {
        try {
            Copy-Item -LiteralPath $immediateBackup -Destination $SavePath -Force
            Write-Host "Restored from backup due to write failure."
            Log "Restored from backup due to write failure."
        } catch {
            Write-Warning "Failed to restore from backup: $($_.Exception.Message)"
            Log "Failed to restore from backup: $($_.Exception.Message)"
        }
    }
    
    # Exit with error
    throw "Failed to write changes to save file."
}

# Refresh PNG thumbnail timestamp (some builds require this)
if (Test-Path -LiteralPath $pngPath) {
    try {
        $tempPng = "$pngPath.new"
        Log 'Refreshing PNG thumbnail timestamp...'
        Copy-Item -LiteralPath $pngPath -Destination $tempPng -Force
        $pngSwapBak = "$pngPath.bak"
        try {
            [System.IO.File]::Replace($tempPng, $pngPath, $pngSwapBak)
        } catch {
            throw "PNG replace failed: $($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $pngSwapBak) { Remove-Item -LiteralPath $pngSwapBak -Force }
        Log 'PNG thumbnail refresh complete (atomic replace).'
    } catch {
        Log ("PNG refresh failed: {0}" -f $_.Exception.Message)
        if (Test-Path "$pngPath.new") { Remove-Item -LiteralPath "$pngPath.new" -Force }
    }
}

Write-Host 'Done. Restart/Reload the save in-game to see the change.'
Log 'Done.'
