# RS_GESTURES -- build the pk3.
#
# Modelled on RS_Grenade's build.ps1, including its most important property:
# VERIFIED OK MEANS THE PK3 IS WELL-FORMED. IT IS NOT A COMPILE CHECK. There is
# no offline ZScript compiler; only a real engine load validates syntax, and a
# ZScript error is fatal AND GLOBAL -- it stops every pk3 after it in the load
# order from compiling too.
#
# So the checks below are the ones makeable without an engine: that every
# #include resolves, that every registered handler is a class that exists, and
# that no class is declared twice.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$out  = Join-Path $root 'RS_GESTURES.pk3'

$include = @('zscript', 'zscript.txt', 'cvarinfo', 'mapinfo', 'menudef')

$files = @()
foreach ($i in $include) {
    $p = Join-Path $root $i
    if (-not (Test-Path $p)) { Write-Host "WARNING: missing $i"; continue }
    if (Test-Path $p -PathType Container) {
        $files += Get-ChildItem $p -Recurse -File
    } else {
        $files += Get-Item $p
    }
}

# ---- checks --------------------------------------------------------------
$zs = Get-ChildItem (Join-Path $root 'zscript') -Recurse -Filter *.zs -File
$declared = @{}
$dupes = @()
foreach ($f in $zs) {
    foreach ($m in [regex]::Matches((Get-Content $f.FullName -Raw), '(?m)^class\s+([A-Za-z0-9_]+)')) {
        $n = $m.Groups[1].Value
        if ($declared.ContainsKey($n)) { $dupes += $n } else { $declared[$n] = $f.Name }
    }
}

$unresolved = @()
foreach ($m in [regex]::Matches((Get-Content (Join-Path $root 'zscript.txt') -Raw), '#include\s+"([^"]+)"')) {
    if (-not (Test-Path (Join-Path $root $m.Groups[1].Value))) { $unresolved += $m.Groups[1].Value }
}

# ZSCRIPT IDENTIFIERS ARE CASE-INSENSITIVE. A field `count` and a method
# `Count()` in one class are the same name; the compiler stops with "Attempt to
# redefine", fatally and globally, taking every pk3 after this one in the load
# order with it. This walks each class body at brace depth 1 -- so locals inside
# methods are never considered -- and compares members case-insensitively.
$collisions = @()
foreach ($f in $zs) {
    $cls = ''; $depth = 0; $members = @{}
    foreach ($line in (Get-Content $f.FullName)) {
        $code = ($line -replace '//.*$', '').Trim()

        if ($depth -eq 0 -and $code -match '^class\s+([A-Za-z_]\w*)') {
            $cls = $Matches[1]; $members = @{}
        }

        if ($cls -and $depth -eq 1 -and $code -and $code -notmatch '^[{}]') {
            $names = @()
            if ($code -match '([A-Za-z_]\w*)\s*\(') {
                $names += $Matches[1]                       # method
            } elseif ($code -match ';$' -and $code -notmatch '^(return|break|continue)\b') {
                foreach ($chunk in ($code -replace ';$', '') -split ',') {
                    $c = ($chunk -replace '=.*$', '').Trim()
                    $ids = [regex]::Matches($c, '[A-Za-z_]\w*')
                    if ($ids.Count) { $names += $ids[$ids.Count - 1].Value }
                }
            }
            foreach ($n in $names) {
                $k = $n.ToLower()
                # -cne, NOT -ne: PowerShell string comparison is case-INSENSITIVE
                # by default, so `-ne` reports "count" and "Count" as equal and
                # this check silently finds nothing. That is the same species of
                # bug it exists to catch, and it shipped once already.
                if ($members.ContainsKey($k) -and $members[$k] -cne $n) {
                    $collisions += "$cls`::$($members[$k]) / $n"
                } else { $members[$k] = $n }
            }
        }

        $depth += ([regex]::Matches($code, '\{')).Count
        $depth -= ([regex]::Matches($code, '\}')).Count
        if ($depth -lt 0) { $depth = 0 }
    }
}

$undef = @()
foreach ($m in [regex]::Matches((Get-Content (Join-Path $root 'mapinfo') -Raw), '"([A-Za-z0-9_]+)"')) {
    if (-not $declared.ContainsKey($m.Groups[1].Value)) { $undef += $m.Groups[1].Value }
}

# Every cvar the menu drives must actually be declared, or the option silently
# does nothing -- an absent cvar reads exactly like one sitting at its default.
$cvars = @{}
foreach ($m in [regex]::Matches((Get-Content (Join-Path $root 'cvarinfo') -Raw), '(?m)^\s*(?:user|server|nosave)\s+\w+\s+([A-Za-z0-9_]+)')) {
    $cvars[$m.Groups[1].Value] = $true
}

$menuMissing = @()
foreach ($m in [regex]::Matches((Get-Content (Join-Path $root 'menudef') -Raw), '(?m)^\s*(?:Option|Slider)\s+"[^"]*",\s*"([A-Za-z0-9_]+)"')) {
    if (-not $cvars.ContainsKey($m.Groups[1].Value)) { $menuMissing += $m.Groups[1].Value }
}

# ---- pack ----------------------------------------------------------------
if (Test-Path $out) { Remove-Item $out -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
try {
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel)
    }
} finally { $zip.Dispose() }

$kb = [math]::Round((Get-Item $out).Length / 1KB, 1)
Write-Host ""
Write-Host "RS_GESTURES.pk3  --  $($files.Count) entries, $kb KB"
Write-Host "  #includes         : $($unresolved.Count) unresolved"
Write-Host "  event handlers    : $($undef.Count) undefined"
Write-Host "  classes           : $($declared.Count) declared, $($dupes.Count) duplicated"
Write-Host "  menu cvars        : $($menuMissing.Count) undeclared"
Write-Host "  member collisions : $($collisions.Count) (case-insensitive)"
if ($unresolved.Count -or $undef.Count -or $dupes.Count -or $menuMissing.Count -or $collisions.Count) {
    if ($unresolved.Count)  { Write-Host "  UNRESOLVED: $($unresolved -join ', ')" }
    if ($undef.Count)       { Write-Host "  UNDEFINED HANDLER: $($undef -join ', ')" }
    if ($dupes.Count)       { Write-Host "  DUPLICATE CLASS: $($dupes -join ', ')" }
    if ($menuMissing.Count) { Write-Host "  MENU CVAR NOT DECLARED: $($menuMissing -join ', ')" }
    if ($collisions.Count)  { Write-Host "  MEMBER COLLISION: $($collisions -join ', ')" }
    Write-Host "  FAILED"
} else {
    Write-Host "  VERIFIED OK  (well-formed -- NOT a ZScript compile check)"
}
