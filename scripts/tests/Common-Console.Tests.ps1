#Requires -Version 7.0
<#
    Tests for Common-Console.psm1: the Doing/Done line, the tallies behind the
    summary, the step banner, and the failure report.

    Every case starts from a fresh import, which is the module's only reset:
    its counters and the open-line flag are private.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console'

function Reset-Console { Import-ScriptModule 'Common-Console' }

function New-ErrorRecord {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    return [System.Management.Automation.ErrorRecord]::new(
        [System.Exception]::new($Message), 'TestError', 'NotSpecified', $null)
}

Write-TestSection '1. Write-Doing and Write-Done make one line'
# Arrange
Reset-Console

# Act
$run = Get-Narration { Write-Doing 'Cloning'; Write-Done }

# Assert
Assert-That 'exactly one line was printed' ($run.Lines.Count -eq 1) ($run.Lines -join ' | ')
Assert-Equal 'the attempt and its outcome share it' -Expected '  ▶ Cloning ... done' `
    -Actual $run.Lines[0]
Assert-That 'counted as one ok' ((Get-ConsoleCounter Ok) -eq 1 -and (Get-ConsoleCounter Skip) -eq 0)

# Act
$run = Get-Narration { Write-Doing 'Deleting'; Write-Done '2 file(s)' }

# Assert
Assert-Equal 'a custom outcome replaces "done"' -Expected '  ▶ Deleting ... 2 file(s)' `
    -Actual $run.Lines[0]

Write-TestSection '2. Write-Done -Skip is the other outcome'
# Arrange
Reset-Console

# Act
$run = Get-Narration { Write-Doing 'Removing scripts/'; Write-Done -Skip }

# Assert
Assert-Equal 'the default skip wording' -Expected '  ▶ Removing scripts/ ... already done' `
    -Actual $run.Lines[0]
Assert-That 'counted as a skip, not an ok' `
    ((Get-ConsoleCounter Skip) -eq 1 -and (Get-ConsoleCounter Ok) -eq 0)

# Act
$run = Get-Narration { Write-Doing 'Retitling'; Write-Done -Skip 'already named' }

# Assert
Assert-Equal 'a custom skip reason' -Expected '  ▶ Retitling ... already named' `
    -Actual $run.Lines[0]

Write-TestSection '3. Write-Done with no line open falls back to a line of its own'
# Arrange
Reset-Console

# Act
$run = Get-Narration { Write-Done }

# Assert
Assert-That 'one full line, with a marker' `
    ($run.Lines.Count -eq 1 -and $run.Lines[0] -match '^  \S+ done$') `
    ($run.Lines -join ' | ')
Assert-That 'still counted as an ok' ((Get-ConsoleCounter Ok) -eq 1)

# Act
$run = Get-Narration { Write-Done -Skip 'nothing to do' }

# Assert
Assert-That 'and the skip form likewise' ($run.Lines[0] -match '^  \S+\s+nothing to do$') `
    ($run.Lines -join ' | ')
Assert-That 'counted as a skip' ((Get-ConsoleCounter Skip) -eq 1)

Write-TestSection '4. any other writer closes an open line first'
# Arrange
Reset-Console

# Act
$run = Get-Narration { Write-Doing 'Pushing'; Write-Warn 'the remote is slow'; Write-Done }

# Assert
Assert-That 'three lines, not one' ($run.Lines.Count -eq 3) ($run.Lines -join ' | ')
Assert-Equal 'the open line was ended where it stood' -Expected '  ▶ Pushing ...' `
    -Actual $run.Lines[0]
Assert-That 'the warning has its own line' ($run.Lines[1] -match 'the remote is slow$')
Assert-That 'and the outcome, orphaned, has its own' ($run.Lines[2] -match 'done$')
Assert-That 'the tallies still count each once' `
((Get-ConsoleCounter Warn) -eq 1 -and (Get-ConsoleCounter Ok) -eq 1)

# Act
$run = Get-Narration {
    Write-Doing 'Reading'
    Write-Detail 'a detail'
    Write-Info 'info'
    Write-Skip 'skip'
}

# Assert
Assert-That 'Detail, Info and Skip all close it too' ($run.Lines.Count -eq 4) `
    ($run.Lines -join ' | ')

Write-TestSection '5. a blank message is made visible'
# Act
$run = Get-Narration { Write-Ok ''; Write-Skip '   '; Write-Warn "`t" }

# Assert
Assert-That 'each blank became "(no message)"' `
    (@($run.Lines -match '\(no message\)$').Count -eq 3) `
    ($run.Lines -join ' | ')

Write-TestSection '6. Show-Summary tallies what was printed'
# Arrange
Reset-Console
Write-Ok 'a' 6>$null
Write-Ok 'b' 6>$null
Write-Doing 'c' 6>$null
Write-Done -Skip 6>$null
Write-Warn 'd' 6>$null

# Act
$run = Get-Narration { Show-Summary }

# Assert
Assert-Equal 'the one-line tally' -Expected '  2 ok · 1 already done · 1 warning(s)' `
    -Actual $run.Lines[-1]

Write-TestSection '7. Write-Step banners the step and names it in a failure'
# Arrange
Reset-Console

# Act
$run = Get-Narration { Write-Step '3' 'Clone the new repo' }

# Assert
Assert-Equal 'a blank line first' -Expected '' -Actual $run.Lines[0]
Assert-That 'the header names the step' `
    ($run.Lines[1].StartsWith('═══ STEP 3 · Clone the new repo '))
Assert-That 'and is padded to the rule width' ($run.Lines[1].Length -eq 72) `
    "length $($run.Lines[1].Length)"

# Act
$run = Get-Narration { Show-Failure -ErrorRecord (New-ErrorRecord 'boom') -Activity 'SCAFFOLDING' }

# Assert
Assert-That 'a failure inside the step says which step' `
    ([bool]($run.Lines -match 'SCAFFOLDING FAILED — STEP 3 · Clone the new repo')) `
    ($run.Lines -join ' | ')

# Arrange
Clear-Step

# Act
$run = Get-Narration { Show-Failure -ErrorRecord (New-ErrorRecord 'boom') -Activity 'SCAFFOLDING' }

# Assert
Assert-That 'after Clear-Step, no step is named' `
    ([bool]($run.Lines -match 'SCAFFOLDING FAILED$') -and -not ($run.Lines -match 'STEP 3')) `
    ($run.Lines -join ' | ')

Write-TestSection '8. Show-Failure reports the reason, and how to carry on'
# Arrange
Reset-Console
try { throw "first line`nsecond line" } catch { $thrown = $_ }

# Act
$run = Get-Narration { Show-Failure -ErrorRecord $thrown -Activity 'RUN' -Resumable }

# Assert
Assert-That 'every line of the message is shown, indented' `
([bool]($run.Lines -match '^  first line$') -and [bool]($run.Lines -match '^  second line$')) `
($run.Lines -join ' | ')
Assert-That 'a real throw shows where it came from' `
    ([bool]($run.Lines -match '^  At .*Common-Console\.Tests\.ps1:\d+$')) `
    ($run.Lines -join ' | ')
Assert-That 'and its stack' ([bool]($run.Lines -match 'Stack trace:'))
Assert-That 'the summary tally is part of the report' `
    ([bool]($run.Lines -match ' ok · .* already done · .* warning\(s\)$'))
Assert-That '-Resumable says to re-run' ([bool]($run.Lines -match 'Re-run to resume'))

# Act
$run = Get-Narration { Show-Failure -ErrorRecord (New-ErrorRecord '') -Activity 'RUN' }

# Assert
Assert-That 'an exception with no message says so' `
    ([bool]($run.Lines -match 'Exception with no message$')) `
    ($run.Lines -join ' | ')
Assert-That 'a record with no script location has no "At" line' (-not ($run.Lines -match '^  At '))
Assert-That 'without -Resumable, no re-run advice' (-not ($run.Lines -match 'Re-run to resume'))

Write-TestSection '9. Add-Change and Get-ChangeCount'
# Arrange
Reset-Console

# Act + Assert
Assert-That 'starts at zero' ((Get-ChangeCount) -eq 0)
Add-Change
Add-Change
Assert-That 'counts each call' ((Get-ChangeCount) -eq 2)
Assert-That 'and prints nothing' ((Get-Narration { Add-Change }).Lines.Count -eq 0)

Write-TestSection '10. Show-Banner, Write-Field, Write-Detail'
# Act
$run = Get-Narration { Show-Banner -Line ' one', ' two' }

# Assert
Assert-That 'a blank, a rule, the lines, a rule' `
    ($run.Lines.Count -eq 5 -and $run.Lines[0] -eq '') `
    ($run.Lines -join ' | ')
Assert-That 'the rule is 72 wide' `
    ($run.Lines[1] -eq ('─' * 72) -and $run.Lines[4] -eq $run.Lines[1])
Assert-Equal 'the lines are printed as given' -Expected ' one' -Actual $run.Lines[2]

# Act
$run = Get-Narration { Write-Field 'Source template' 'o/r'; Write-Field '' 'C:\x' }

# Assert
Assert-That 'the value starts in a fixed column' ($run.Lines[0].IndexOf('o/r') -eq 23) $run.Lines[0]
Assert-That 'an empty label leaves the value in that column' `
    ($run.Lines[1].IndexOf('C:\x') -eq 23)
    $run.Lines[1]

# Act
$run = Get-Narration { Write-Detail 'under the line above' }

# Assert
Assert-That 'a detail is indented under the message column' `
    ($run.Lines[0] -match '^ {7}under the line above$') `
    $run.Lines[0]

Write-TestSection '11. the module surface'
$exported = (Get-Command -Module Common-Console).Name
foreach ($n in 'Format-MessageText', 'Close-OpenLine', 'Write-FailureReason',
    'Write-FailureLocation', 'Write-FailureStack') {
    Assert-That "$n stays private" ($n -notin $exported)
}

foreach ($n in 'Write-Ok', 'Write-Skip', 'Write-Warn', 'Write-Info', 'Write-Detail', 'Write-Field',
    'Write-Doing', 'Write-Done', 'Show-Banner', 'Write-Step', 'Clear-Step', 'Show-Summary',
    'Show-Failure', 'Add-Change', 'Get-ChangeCount') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
