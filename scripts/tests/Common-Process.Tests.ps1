#Requires -Version 7.0
<#
    Tests for Common-Process.psm1: running a native command and getting its
    exit code and output back in a shape callers can rely on. pwsh itself is
    the native command under test - the one executable every machine running
    these tests is guaranteed to have.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-Process'

$pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

# The child's own output encoding is pinned as well, so what is under test is
# how THIS side decodes, not what the child happens to emit.
function Get-ChildArgument {
    param([Parameter(Mandatory)][string]$Script)

    $prelude = '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); '
    return , @('-NoProfile', '-NonInteractive', '-Command', ($prelude + $Script))
}

function Invoke-Read {
    param([Parameter(Mandatory)][string]$Script)

    return Invoke-NativeRead -Command $pwsh -Arguments (Get-ChildArgument $Script)
}

Write-TestSection '1. Invoke-NativeRead returns Ok and the output in a fixed shape'
# Act
$zero = Invoke-Read 'exit 0'
$one = Invoke-Read 'Write-Output one'
$two = Invoke-Read 'Write-Output one; Write-Output two'

# Assert
Assert-That 'a clean exit is Ok' ($zero.Ok -eq $true)
Assert-That 'no output is an empty array, not $null' `
    ($zero.Output -is [array] -and $zero.Output.Count -eq 0)
Assert-That 'one line is a one-element array of a string' `
($one.Output.Count -eq 1 -and $one.Output[0] -is [string]) "got count=$($one.Output.Count)"
Assert-Equal 'with the line itself' -Expected 'one' -Actual $one.Output[0]
Assert-That 'two lines are two strings' ($two.Output.Count -eq 2 -and $two.Output[1] -eq 'two') `
($two.Output -join ' | ')

Write-TestSection '2. a failing command is reported, not thrown'
# Arrange
$global:LASTEXITCODE = 0

# Act
$failed = Invoke-Read 'Write-Output oops; exit 3'

# Assert
Assert-That 'Ok is false' ($failed.Ok -eq $false)
Assert-That 'what it printed is still there' ($failed.Output -contains 'oops') `
    ($failed.Output -join ' | ')
Assert-That '$LASTEXITCODE is not left at the failure' ($LASTEXITCODE -eq 0) `
    "LASTEXITCODE=$LASTEXITCODE"

Write-TestSection '3. standard error is folded into the output'
# Act
$mixed = Invoke-Read '[Console]::Error.WriteLine("to stderr"); Write-Output "to stdout"'

# Assert
Assert-That 'both streams come back as lines' `
    (($mixed.Output -match 'to stderr') -and ($mixed.Output -match 'to stdout')) `
    ($mixed.Output -join ' | ')
Assert-That 'and stderr alone does not make it a failure' ($mixed.Ok -eq $true)

Write-TestSection '4. output is decoded as UTF-8 whatever the console encoding is'
# Arrange: a single-byte console encoding, under which UTF-8 bytes for 'é'
# would decode as two characters.
$before = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::Latin1

# Act
try { $read = Invoke-Read "Write-Output 'café ✓'" }
finally {
    $after = [Console]::OutputEncoding
    [Console]::OutputEncoding = $before
}

# Assert
Assert-Equal 'non-ASCII output survives' -Expected 'café ✓' -Actual $read.Output[0]
Assert-Equal 'and the console encoding is put back afterwards' -Expected 'iso-8859-1' `
    -Actual $after.WebName

Write-TestSection '5. -StdIn feeds the command'
# Act
$fed = Invoke-NativeCommand -Activity 'Feeding' -Command $pwsh `
    -Arguments (Get-ChildArgument '$input | ForEach-Object { "got $_" }') -StdIn "a`nb"

# Assert
Assert-That 'each line arrived' (($fed -contains 'got a') -and ($fed -contains 'got b')) `
    ($fed -join ' | ')

Write-TestSection '6. Invoke-NativeCommand throws on failure, and returns the output otherwise'
# Act + Assert
Assert-Throws 'a non-zero exit throws, naming the activity and what was said' `
    -Match '(?s)Probing failed.*oops' {
    Invoke-NativeCommand -Activity 'Probing' -Command $pwsh `
        -Arguments (Get-ChildArgument 'Write-Output oops; exit 3')
}

# Act
$ok = Invoke-NativeCommand -Activity 'Listing' -Command $pwsh `
    -Arguments (Get-ChildArgument 'Write-Output only')
$none = Invoke-NativeCommand -Activity 'Quiet' -Command $pwsh `
    -Arguments (Get-ChildArgument 'exit 0')

# Assert
Assert-That 'a clean exit returns the output as an array' `
    ($ok -is [array] -and $ok.Count -eq 1 -and $ok[0] -eq 'only')
Assert-That 'no output is an empty array' ($none -is [array] -and $none.Count -eq 0)

Write-TestSection '7. the module surface'
$exported = (Get-Command -Module Common-Process).Name
Assert-That 'Invoke-NativeCapture stays private' ('Invoke-NativeCapture' -notin $exported)
foreach ($n in 'Invoke-NativeCommand', 'Invoke-NativeRead') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
