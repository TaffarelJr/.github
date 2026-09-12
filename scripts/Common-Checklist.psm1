#Requires -Version 7.0
<#
    A checklist of things a script cannot do for itself.

    Items are queued as they are decided - some from a fixed list, some only
    when a call that should have worked did not - then printed once at the
    end, so the run reads as a single list of what is left rather than
    instructions scattered through the log.

    What goes on the list is the caller's business; this only keeps it and
    prints it.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# State
#───────────────────────────────────────────────────────────────────────────────

$script:ManualItems = [System.Collections.Generic.List[object]]::new()

#───────────────────────────────────────────────────────────────────────────────
# Queue
#───────────────────────────────────────────────────────────────────────────────

function Add-ManualItem {
    <#
    .SYNOPSIS
        Adds one entry to the end-of-run manual checklist.
    .PARAMETER Category
        The heading to file it under. Grouped by text, ignoring case, so a
        caller with more than one item to add should hold this in a constant
        rather than repeat the string - two spellings print as two headings.
    .PARAMETER Steps
        How to do it. One console line each, so a single instruction has to be
        one element - splitting a sentence across two prints it as two steps.
    #>
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Steps = @()
    )

    $script:ManualItems.Add([pscustomobject]@{
            Category = $Category
            Title    = $Title
            Steps    = $Steps
        })
}

function Show-ManualChecklist {
    <#
    .SYNOPSIS
        Prints everything Add-ManualItem queued, grouped by category.
    .PARAMETER OwnerRepo
        Named in the banner only. The queue is module-wide, not per repo.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    if ($script:ManualItems.Count -eq 0) {
        Write-Info 'No manual follow-up needed'
        return
    }

    Show-Banner -Color Yellow -Line @(
        " 📋 MANUAL FOLLOW-UP — $OwnerRepo"
        '    Do these by hand when convenient.'
    )

    foreach ($group in ($script:ManualItems | Group-Object Category)) {
        Write-Host ""
        Write-Host "  ▸ $($group.Name)" -ForegroundColor Cyan
        $number = 1
        foreach ($item in $group.Group) {
            # Steps hang under the title text, so the pad is measured from the
            # prefix rather than fixed - it has to grow at item 10.
            $prefix = "    $number. [ ] "
            Write-Host "$prefix$($item.Title)" -ForegroundColor White
            $pad = ' ' * $prefix.Length
            foreach ($step in $item.Steps) {
                Write-Host "$pad$step" -ForegroundColor DarkGray
            }

            $number++
        }
    }

    Write-Host ""
}

function Write-ManualChecklistFile {
    <#
    .SYNOPSIS
        Writes everything Add-ManualItem queued to NEXT-STEPS.md, so it
        survives past the console and can be opened as a file.
    .DESCRIPTION
        Mirrors Show-ManualChecklist's grouping, as Markdown checkboxes
        instead of a console banner. Always overwrites: the file is a
        snapshot of this run, not something to preserve edits to, and the
        reader is expected to delete it once every box is checked.
    .OUTPUTS
        [string] - the file's path, or $null if there was nothing to queue.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    if ($script:ManualItems.Count -eq 0) { return $null }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@(
            '# Next Steps'
            ''
            "Do these by hand when convenient. Delete this file once they're all"
            'checked - it is not part of the repo.'
        ))

    foreach ($group in ($script:ManualItems | Group-Object Category)) {
        $lines.Add('')
        $lines.Add("## $($group.Name)")
        foreach ($item in $group.Group) {
            $lines.Add('')
            $lines.Add("- [ ] $($item.Title)")
            foreach ($step in $item.Steps) {
                $lines.Add("      $step")
            }
        }
    }

    $path = Join-Path $RepoPath 'NEXT-STEPS.md'
    Write-TextFile -Path $path -Lines ([string[]]@($lines))
    return $path
}

Export-ModuleMember -Function @(
    'Add-ManualItem'
    'Show-ManualChecklist'
    'Write-ManualChecklistFile'
)
