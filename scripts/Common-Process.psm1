#Requires -Version 7.0
<#
    Running an external command and noticing when it fails.

    A native command exiting non-zero does NOT stop PowerShell, whatever
    $ErrorActionPreference says. So every external call has to be checked
    explicitly, or a failure is silently reported as success - which is the
    single easiest way for a script here to lie about what it did.

    This captures the command's own output rather than letting it scribble
    over the log, and folds it into the error when something breaks, so a
    failure says what went wrong instead of just that it did.

    Two decisions live here. What a failed external command looks like - and
    each domain module wraps it with the knowledge of its own tool. And how
    the command's output is decoded: PowerShell decodes it with whatever code
    page the console inherited, which on Windows depends on the shell that
    launched it - UTF-8 from one terminal, CP437 from another - and a
    non-ASCII path read under the wrong one names no file on disk.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

function Invoke-NativeCapture {
    <#
    .SYNOPSIS
        Runs an external command and returns its exit code and merged output.
    .DESCRIPTION
        Not exported. The one place output is captured and decoded, so the
        two exported wrappers cannot disagree about either.

        stderr is merged into the captured output on purpose, not by accident:
        git reports ordinary success there - 'Everything up-to-date' among
        others - and gh writes its error bodies to stdout, so a caller
        inspecting the result needs both streams. It also keeps a
        chatty-but-successful command from surfacing as a NativeCommandError.

        The console's output encoding is pinned to UTF-8 for the call and put
        back after: git and gh emit UTF-8 whatever the code page is, so
        decoding with anything else corrupts every non-ASCII byte. Restored so
        the host's own rendering is untouched.
    .OUTPUTS
        [hashtable] @{ ExitCode = [int]; Output = [string[]] } - Output is
        always an array, possibly empty.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$StdIn
    )

    $consoleEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $out = if ($PSBoundParameters.ContainsKey('StdIn')) {
            $StdIn | & $Command @Arguments 2>&1
        }
        else {
            & $Command @Arguments 2>&1
        }

        $exitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $consoleEncoding
    }

    # Typed, so one line stays an array rather than becoming a string. Not an
    # if-expression: one that emits an empty array emits nothing, and the
    # variable would end up $null instead of empty. And '@($null)' would be an
    # array of one $null, so a command that printed nothing needs the guard.
    [string[]]$lines = @()
    if ($null -ne $out) { $lines = $out }
    return @{ ExitCode = $exitCode; Output = $lines }
}

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Runs an external command with its output captured, and throws if it
        fails.
    .DESCRIPTION
        Only for calls where a non-zero exit is genuinely an error. A call
        whose failure is an answer rather than an error goes through
        Invoke-NativeRead instead.
    .PARAMETER Activity
        What was being attempted, as a phrase that reads before 'failed'.
    .PARAMETER Arguments
        Must be an explicit array. Loose tokens bind as PowerShell parameters
        instead of arguments to the command, without any error.
    .PARAMETER StdIn
        Piped to the command instead of appearing in its arguments. For a
        value that must not reach the console: the failure message renders the
        whole argument vector, so a secret passed as an argument would be
        printed by the failure banner and written to any transcript.
    .OUTPUTS
        [string[]] - the command's output lines, always as an array. The
        leading comma on the return is what keeps one line from unrolling to a
        scalar on the way out; it also means a caller must NOT wrap the call
        in @(), which would nest the array inside another.
    #>
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$StdIn
    )

    $extra = @{}
    if ($PSBoundParameters.ContainsKey('StdIn')) { $extra['StdIn'] = $StdIn }
    $result = Invoke-NativeCapture -Command $Command -Arguments $Arguments @extra
    if ($result.ExitCode -ne 0) {
        $detail = ($result.Output | Out-String).Trim()
        throw ("$Activity failed: $Command $($Arguments -join ' ') " +
            "(exit $($result.ExitCode))" +
            $(if ($detail) { "`n$detail" } else { '' }))
    }

    return , $result.Output
}

function Invoke-NativeRead {
    <#
    .SYNOPSIS
        Runs an external command whose failure is survivable, and returns
        whether it worked along with what it said.
    .DESCRIPTION
        Never throws. For a read whose failure must not end the run, but must
        not be mistaken for an answer either: the exit code is reported rather
        than discarded, and the output is kept whatever it was - gh writes its
        error bodies to stdout, and a caller may need to read them. Resets
        $LASTEXITCODE, so a tolerated failure leaves no phantom behind for a
        later check to trip on.
    .OUTPUTS
        [hashtable] @{ Ok = [bool]; Output = [string[]] }
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $result = Invoke-NativeCapture -Command $Command -Arguments $Arguments
    $global:LASTEXITCODE = 0
    return @{ Ok = ($result.ExitCode -eq 0); Output = $result.Output }
}

Export-ModuleMember -Function @(
    'Invoke-NativeCommand'
    'Invoke-NativeRead'
)
