#Requires -Version 7.0
<#
    Token substitution across a working tree.

    Two passes, in this order: file contents, then names longest-path-first.
    Contents first because the item list is a snapshot taken up front, and a
    rename would stale the path of any file not yet read. Names
    longest-path-first for the same reason in miniature: renaming a parent
    would stale every path beneath it.

    Neither pass stops at its first failure. The token has already been
    replaced elsewhere by then, and a tree that is half one name and half
    the other is easier to reason about with every gap named at once than
    with only the first. So each pass collects what it could not do, and the
    whole rename throws at the end if anything is on that list - a commit
    must never land on a tree that still says both names.

    Content is read and written through Common-File, so a file's encoding
    and line ending survive the rewrite.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# Tokens
#───────────────────────────────────────────────────────────────────────────────

function Get-TokenCandidate {
    <#
    .SYNOPSIS
        Returns every item under a repo that a token pass is allowed to touch.
    .DESCRIPTION
        Not exported. Warns about a subtree it could not read instead of
        dropping it, so a partial pass cannot pass for a complete one. This is
        the one failure that only warns: nothing has been changed yet, and
        there is nothing to rename in a folder that could not be listed.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Exclude
    )

    $root = (Resolve-Path -LiteralPath $RepoPath).Path.TrimEnd('\', '/')
    $escaped = ($Exclude | ForEach-Object { [regex]::Escape($_) }) -join '|'

    # Matched against each path RELATIVE to the repo. Against the absolute
    # path, a repo that merely lives under a folder named 'bin' or 'scripts'
    # would exclude its own entire tree and report finding nothing.
    $excludePattern = "(^|[\\/])($escaped)([\\/]|`$)"

    $items = Get-ChildItem -LiteralPath $root -Recurse -Force `
        -ErrorAction SilentlyContinue -ErrorVariable failures
    foreach ($failure in $failures) {
        Write-Warn "Not searched: $($failure.TargetObject) - $($failure.Exception.Message)"
    }

    return @($items | Where-Object {
            $_.FullName.Substring($root.Length) -notmatch $excludePattern
        })
}

function Update-FileToken {
    <#
    .SYNOPSIS
        Replaces a token in one file's content, keeping its encoding and
        line ending.
    .DESCRIPTION
        Declines any file whose decoded text contains a NUL, which is the
        reliable mark of binary content: an extension deny-list cannot list
        every binary format, and rewriting one as text destroys it.
    .OUTPUTS
        [bool] - whether the file was rewritten.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$From,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$To
    )

    $file = Read-TextFile -Path $Path
    if (-not $file.Content.Contains($From)) { return $false }
    if ($file.Content.Contains([char]0)) {
        Write-Warn "Skipped binary content: $Path"
        return $false
    }

    Write-TextFile -Path $Path -Content $file.Content.Replace($From, $To)
    return $true
}

function Update-ContentToken {
    <#
    .SYNOPSIS
        Replaces a token in the content of every eligible file.
    .DESCRIPTION
        Not exported. A file that cannot be read or written is recorded and
        stepped over, so the caller can name every gap at once - see the
        module header.
    .OUTPUTS
        [pscustomobject] with Edited (how many files were rewritten) and
        Failed (one "<path> - <reason>" line per file that could not be).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string[]]$SkipExtension
    )

    $edited = 0
    $failed = [System.Collections.Generic.List[string]]::new()
    $files = @($Item | Where-Object {
            -not $_.PSIsContainer -and $_.Extension -notin $SkipExtension
        })

    foreach ($file in $files) {
        try {
            if (Update-FileToken -Path $file.FullName -From $From -To $To) { $edited++ }
        }
        catch {
            $failed.Add("$($file.FullName) - $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{ Edited = $edited; Failed = @($failed) }
}

function Rename-NameToken {
    <#
    .SYNOPSIS
        Replaces a token in file and directory names.
    .DESCRIPTION
        Not exported. A rename that fails - usually because the target already
        exists - is recorded with both paths, since the operator can only clear
        it if told which one, and the pass moves on to the next item.
    .OUTPUTS
        [pscustomobject] with Renamed (how many items were renamed) and Failed
        (one "<from> -> <to> - <reason>" line per item that could not be).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    # Longest path first. A child's path is always longer than its parent's,
    # so this reaches every item before its own ancestors without assuming a
    # separator character.
    $named = @($Item |
        Where-Object { $_.Name.Contains($From) } |
        Sort-Object { $_.FullName.Length } -Descending)

    $renamed = 0
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $named) {
        $newName = $item.Name.Replace($From, $To)
        try {
            Rename-Item -LiteralPath $item.FullName -NewName $newName
            $renamed++
        }
        catch {
            $failed.Add("$($item.FullName) -> $newName - $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{ Renamed = $renamed; Failed = @($failed) }
}

function Rename-Token {
    <#
    .SYNOPSIS
        Replaces a placeholder token in file content, file names,
        and directory names.
    .DESCRIPTION
        Case-sensitive throughout, so a token differing from its replacement
        only in case is still a rename.

        Does nothing, and says so, when there is nothing to replace. Throws
        at the END, naming every item it could not change, if either pass
        left a gap - see the module header for why the end and not the first.
    .PARAMETER SkipExtension
        Binary-ish extensions not worth reading. Content that turns out to be
        binary anyway is detected and left alone, so this list is a shortcut
        rather than the safeguard.
    .PARAMETER Exclude
        Directory names to skip entirely: the git database, build output,
        dependency caches, and scripts/ - which is where a token is DEFINED
        and documented rather than used, so renaming it there would rewrite
        the definition and every deeper layer would then rename the wrong
        word.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container },
            ErrorMessage = "no such folder '{0}'")]
        [string]$RepoPath,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$From,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$To,
        [string[]]$SkipExtension = @(
            '.png', '.jpg', '.jpeg', '.gif', '.ico', '.svg',
            '.pdf', '.zip', '.dll', '.exe', '.snk'
        ),
        [string[]]$Exclude = @('.git', 'bin', 'obj', 'node_modules', 'scripts')
    )

    # Ordinal, because the replacement itself is: -eq would call 'Placeholder'
    # and 'placeholder' equal and skip a rename that has real work to do.
    if ([string]::Equals($From, $To, 'Ordinal')) {
        Write-Skip "Nothing to rename ('$From' is already '$To')"
        return
    }

    # Both checked before the content pass mutates anything, so an unusable
    # name cannot leave a tree whose contents are renamed and whose paths are
    # not.
    $illegal = [System.IO.Path]::GetInvalidFileNameChars()
    if ($To.IndexOfAny($illegal) -ge 0) {
        throw "Cannot rename '$From' to '$To': not a legal file name"
    }

    # A new name that CONTAINS the old one is not re-runnable: the next run
    # finds 'Placeholder' inside every 'PlaceholderLib' it wrote last time and
    # renames those too. Every gated group has to survive being run again.
    if ($To.Contains($From)) {
        throw ("Cannot rename '$From' to '$To': the new name contains the old " +
            'one, so a re-run would rename it again')
    }

    Write-Doing "Renaming '$From' -> '$To'"
    $items = Get-TokenCandidate -RepoPath $RepoPath -Exclude $Exclude
    $content = Update-ContentToken -Item $items -From $From -To $To -SkipExtension $SkipExtension
    $names = Rename-NameToken -Item $items -From $From -To $To

    $failed = @($content.Failed) + @($names.Failed)
    if ($failed) {
        throw ("Could not rename '$From' -> '$To' in $($failed.Count) item(s):`n  " +
            ($failed -join "`n  "))
    }

    if ($content.Edited -eq 0 -and $names.Renamed -eq 0) {
        Write-Done -Skip "no '$From' found"
        return
    }

    Add-Change
    Write-Done "$($content.Edited) file(s) edited, $($names.Renamed) path(s) renamed"
}

Export-ModuleMember -Function @(
    'Update-FileToken'
    'Rename-Token'
)
