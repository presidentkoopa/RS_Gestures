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

# ---- A NAME GATE, BEFORE ANYTHING IS PACKED -------------------------------------------------------
#
# ZSCRIPT IDENTIFIERS ARE CASE-INSENSITIVE, which produces two failures that look nothing like each
# other on the page and both of which refuse the class AT LOAD -- taking every pk3 after this one
# down with it:
#
#   1. A STATE KEYWORD USED AS A NAME. `stop`, `wait`, `loop`, `fail`, `goto`, `light`, `offset`,
#      `frame`, `sprite`, `line`, `until` are reserved EVERYWHERE, not only inside a States block.
#      `double stop = ...` is "Unexpected 'stop'" -- and because the declaration fails, the name then
#      does not exist at its USE, so one slip gives two errors and the second is twenty lines from
#      anything suspicious. This applies to LOCALS as much as to fields.
#
#   2. A CLASS-SCOPE FIELD AND A METHOD SHARING A NAME. `private double points;` beside
#      `double Points()` is "Attempt to redefine 'points'". Different case, different KIND of thing,
#      still one name.
#
# THE SECOND CHECK IS CLASS SCOPE ONLY, and that distinction is the whole difficulty: a LOCAL may
# share a name with a method perfectly legally, and this pack has three that do and compile green
# (`caught`, `swing`, `inhand`). A gate that flagged those would be a gate nobody ran. So brace depth
# is tracked, and only declarations at depth 1 -- the class body -- count as fields.
#
# IT IS A GATE AND NOT A NOTE BECAUSE I WROTE THE NOTE AND BROKE THE RULE AN HOUR LATER, in a file
# created after I had run the sweep by hand. Five of these cost a compile each in one night: until,
# line, HOOK/hook, stop, and points/Points. A check that depends on remembering to run it is not a
# check.
$reserved = @('stop','wait','loop','fail','goto','light','offset','frame','sprite','line','until')
$types    = 'double|int|bool|String|Name|Actor|Color|Vector3|Vector2|CVar|uint|float|let'
$nameErrs = @()
foreach ($zs in (Get-ChildItem (Join-Path $root 'zscript') -Recurse -File -Filter *.zs)) {
    $text  = Get-Content $zs.FullName
    $flds  = @{}
    $meths = @{}
    $depth = 0
    for ($i = 0; $i -lt $text.Count; $i++) {
        $l = $text[$i]
        if ($l.TrimStart().StartsWith('//')) { continue }
        $bare = $l -replace '//.*$', ''
        $declDepth = $depth           # the depth this line is declared AT, before its own braces
        $depth += ([regex]::Matches($bare, '\{')).Count - ([regex]::Matches($bare, '\}')).Count

        if ($bare -match "(?:^|\s)(?:$types)\s+([A-Za-z_]\w*)\s*(?:\[\s*\d*\s*\])?\s*[;,=]") {
            $n = $Matches[1]
            # A RESERVED WORD IS FATAL AT ANY DEPTH -- a local named `stop` refuses just as hard.
            if ($reserved -contains $n.ToLower()) {
                $nameErrs += "$($zs.Name):$($i+1)  '$n' is a ZScript state keyword and cannot be a name"
            }
            # ...but only a CLASS-SCOPE declaration can collide with a method name.
            if ($declDepth -eq 1) { $flds[$n.ToLower()] = $i + 1 }
        }
        if ($declDepth -eq 1 -and $bare -match '^\s*(?:static\s+|private\s+|override\s+|virtual\s+|clearscope\s+|play\s+|ui\s+)*[A-Za-z0-9_<>]+\s+([A-Za-z_]\w*)\s*\(') {
            $meths[$Matches[1].ToLower()] = $i + 1
        }
    }
    foreach ($k in $meths.Keys) {
        if ($flds.ContainsKey($k)) {
            $nameErrs += "$($zs.Name): '$k' is both a field (line $($flds[$k])) and a method (line $($meths[$k])) -- identifiers are case-insensitive"
        }
    }
}
if ($nameErrs.Count -gt 0) {
    $nameErrs | ForEach-Object { Write-Output "  NAME: $_" }
    throw "name gate failed: $($nameErrs.Count) problem(s) that would refuse a class AT LOAD"
}
Write-Output "name gate passed"

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
