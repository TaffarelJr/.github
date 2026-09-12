#Requires -Version 7.0
<#
    GitHub operations, through the gh CLI and the REST API.

    The account is borrowed into this process's environment rather than
    switched globally, so a run does not repoint every other shell on the
    machine. The one exception is the 'gh auth login' fallback, which does
    change the active account - and which Reset-GhAccount undoes.

    Every setting here is checked before it is written, so a second run
    reports "already done" instead of writing again. Enable-Codeql is the
    exception, and says why in its own help.

    A check that cannot be READ is never treated as a check that came back
    empty: gh writes its error bodies to stdout, so an unguarded read hands
    back plausible-looking nothing, and writing on the strength of it is how
    a scaffold silently overwrites something that was already right.

    Every gh call goes through Invoke-Gh or Invoke-GhRead, so nothing else
    here knows how gh reports failure or what encoding it speaks. The one
    raw call left is 'gh auth login', which has to own the console.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# State and constants
#───────────────────────────────────────────────────────────────────────────────

# The single account these scripts work against. Substituting another one here
# is the whole of what somebody else would need to change to reuse them.
$script:RepoOwner = 'TaffarelJr'

function Get-RepoOwner {
    <#
    .SYNOPSIS
        Returns the GitHub account that owns every template layer,
        and everything derived from one.
    #>
    return $script:RepoOwner
}

# The checklist heading every manual setting below is filed under. A constant
# because the checklist groups by this string: one character of difference
# between two of the call sites would silently print two nearly identical
# headings, each numbered from 1.
$script:ManualSettingCategory = 'GitHub settings — web UI only (no API)'

# Pushed by Use-GhAccount, popped by Reset-GhAccount.
$script:GhStatePushed = $false
$script:PriorGhToken = $null
$script:PriorGhAccount = $null

# CodeQL languages this run should analyse. Layers add to it;
# Enable-Codeql applies the union at the end. Seeded with 'actions'
# because every repo here carries workflows, AND the inherited "Status checks
# must pass" ruleset requires the `Analyze (actions)` check - dropping it would
# leave that check permanently pending and block every PR.
$script:CodeqlLanguages = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('actions'), [System.StringComparer]::OrdinalIgnoreCase)

# The complete set GitHub accepts for code scanning default setup.
$script:CodeqlValidLanguages = @(
    'actions'                 # GitHub Actions workflows
    'c-cpp'                   # C and C++
    'csharp'                  # C#
    'go'                      # Go
    'java-kotlin'             # Java and Kotlin
    'javascript-typescript'   # JavaScript and TypeScript
    'python'                  # Python
    'ruby'                    # Ruby
    'swift'                   # Swift
)

#───────────────────────────────────────────────────────────────────────────────
# Running gh
#───────────────────────────────────────────────────────────────────────────────

function Invoke-Gh {
    <#
    .SYNOPSIS
        Runs gh with its output captured, and throws if it fails.
    .DESCRIPTION
        Only for calls where failure is genuinely an error. A call that USES
        the exit code as its answer, or tolerates a failure, goes through
        Invoke-GhRead.
    .PARAMETER Arguments
        Must be an explicit array. Loose tokens bind as PowerShell parameters
        instead of gh arguments, without any error.
    .PARAMETER StdIn
        Piped to gh instead of appearing in its arguments, for a value that
        must not reach the console. Use it for every secret: the failure
        message renders the whole argument vector.
    #>
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$StdIn
    )

    $extra = @{}
    if ($PSBoundParameters.ContainsKey('StdIn')) { $extra['StdIn'] = $StdIn }
    return Invoke-NativeCommand -Activity $Activity -Command 'gh' -Arguments $Arguments @extra
}

function Invoke-GhRead {
    <#
    .SYNOPSIS
        Runs a gh command whose failure is survivable, returning whether it
        worked and what it said.
    .DESCRIPTION
        Never throws. For a read whose failure must not end the run but must
        not be mistaken for an answer either. Invoke-Gh would throw; discarding
        the exit code would leave an empty result meaning either 'nothing' or
        'no idea', and gh writes its error bodies to stdout, so 'no idea' looks
        like data.

        Every caller that decides whether to WRITE something based on a read
        goes through this, and so does every write whose failure is tolerated.
    .OUTPUTS
        [hashtable] @{ Ok = [bool]; Output = [string[]] }
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)

    return Invoke-NativeRead -Command 'gh' -Arguments $Arguments
}

function Register-UncheckedSetting {
    <#
    .SYNOPSIS
        Reports that a setting was left alone because its current value could
        not be read, and queues it for a human.
    .DESCRIPTION
        Not exported. The safe response to an unreadable check is to write
        nothing: the value may already be right, and overwriting it blind is
        the one outcome that cannot be undone from here.
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string[]]$Steps
    )

    Write-Warn "Could not check $What - left alone, and added to the checklist"
    Add-ManualItem -Category $script:ManualSettingCategory -Title "Check $What" -Steps $Steps
}

#───────────────────────────────────────────────────────────────────────────────
# Authentication
#───────────────────────────────────────────────────────────────────────────────

function Get-ActiveGhAccount {
    <#
    .SYNOPSIS
        Returns the login gh is authenticating as, or $null if the call failed
        or answered with something that is not a login.
    .DESCRIPTION
        Not exported. gh writes error bodies to STDOUT, so a failed call
        returns JSON rather than nothing - which would otherwise be captured
        and later fed to `gh auth switch --user`. Guard on the exit code, then
        reject anything with JSON punctuation. Deny-listing rather than
        allow-listing, because logins legitimately contain characters like the
        underscore in enterprise-managed accounts.
    #>
    $read = Invoke-GhRead -Arguments @('api', 'user', '--jq', '.login')
    if (-not $read.Ok) { return $null }

    $login = ($read.Output -join '').Trim()
    if (-not $login -or $login -match '[\s{}\[\]":,]') { return $null }
    return $login
}

function Get-GhToken {
    <#
    .SYNOPSIS
        Returns the stored token for a gh account, or $null if it has none.
    .DESCRIPTION
        Not exported. A missing token is an answer, not an error: it is what
        sends Use-GhAccount to the interactive login.
    #>
    param([Parameter(Mandatory)][ValidatePattern('\S')][string]$Account)

    $read = Invoke-GhRead -Arguments @('auth', 'token', '--user', $Account)
    if (-not $read.Ok) { return $null }

    $token = ($read.Output -join '').Trim()
    if (-not $token) { return $null }
    return $token
}

function Request-GhLogin {
    <#
    .SYNOPSIS
        Walks the operator through 'gh auth login' for an account, and returns
        the token it stored.
    .DESCRIPTION
        Not exported. The one raw gh call in this module: the login owns the
        console for its browser-or-token prompt, so its output cannot be
        captured. It also makes the account it signs in as the active one,
        which Reset-GhAccount undoes.
    #>
    param([Parameter(Mandatory)][ValidatePattern('\S')][string]$Account)

    Write-Warn "No stored credentials for gh account '$Account' - starting 'gh auth login'"
    Write-Detail "sign in as '$Account'; your other accounts stay logged in"
    gh auth login --hostname github.com
    $loggedIn = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0
    if (-not $loggedIn) { throw "'gh auth login' did not complete." }

    $token = Get-GhToken -Account $Account
    if (-not $token) {
        throw "Still no credentials for '$Account' - did you sign in as a different account?"
    }

    return $token
}

function Test-GhAdminAccess {
    <#
    .SYNOPSIS
        Returns whether the current token can read a repo's workflow
        permissions - the cheapest call that needs admin.
    .DESCRIPTION
        Not exported. Being logged in is not the same as having the scopes the
        rest of this module needs.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo)

    $probe = "repos/$OwnerRepo/actions/permissions/workflow"
    return (Invoke-GhRead -Arguments @('api', $probe, '--silent')).Ok
}

function Use-GhAccount {
    <#
    .SYNOPSIS
        Points this process's gh calls at the repo owner,
        then verifies it has admin access.
    .DESCRIPTION
        Borrows the owner's token into $env:GH_TOKEN, rather than running
        `gh auth switch`, which would repoint every other shell on the
        machine. Records any prior GH_TOKEN and active account first, so
        Reset-GhAccount can put both back exactly as they were. Recorded once:
        calling this twice without an intervening reset keeps the first
        reading, which is the caller's own.
    .PARAMETER Account
        The gh account whose token to borrow. Defaults to the owner constant,
        so a caller only passes this to override it.
    .PARAMETER ProbeOwnerRepo
        A repo the account must have admin access to - the source template.
    #>
    param(
        [ValidatePattern('\S')][string]$Account = (Get-RepoOwner),
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$ProbeOwnerRepo
    )

    # Push the state we are about to change, so the pop can be exact rather
    # than approximate. First push wins: a second call would otherwise record
    # the token this one borrowed, and the pop would restore that instead of
    # the caller's own.
    if (-not $script:GhStatePushed) {
        $script:PriorGhToken = $env:GH_TOKEN
        $script:PriorGhAccount = Get-ActiveGhAccount
        $script:GhStatePushed = $true
    }

    Write-Doing "Borrowing gh account '$Account' for this run"
    $token = Get-GhToken -Account $Account
    if (-not $token) { $token = Request-GhLogin -Account $Account }
    $env:GH_TOKEN = $token

    $active = Get-ActiveGhAccount
    if (-not $active) { throw "Not authenticated with gh. Run 'gh auth login' first." }
    if (-not (Test-GhAdminAccess -OwnerRepo $ProbeOwnerRepo)) {
        throw ("Account '$active' lacks admin access to '$ProbeOwnerRepo'. If it is a " +
            'scope issue, run: gh auth refresh -h github.com ' +
            '-s admin:repo_hook,workflow,security_events')
    }

    Write-Done "admin access confirmed as '$active'"
}

function Restore-GhAccount {
    <#
    .SYNOPSIS
        Makes an account gh's active one again, and returns whether that took.
    .DESCRIPTION
        Not exported. Only needed when the interactive login changed the active
        account; a failure here is reported, not swallowed, because the
        operator's other shells are what it leaves pointing at the wrong
        account.
    #>
    param([Parameter(Mandatory)][ValidatePattern('\S')][string]$Account)

    $active = Get-ActiveGhAccount
    if (-not $active -or $active -eq $Account) { return $true }

    $switch = Invoke-GhRead -Arguments @('auth', 'switch', '--user', $Account)
    if (-not $switch.Ok) {
        Write-Warn ("Could not make '$Account' the active gh account again - " +
            "run: gh auth switch --user $Account")
        return $false
    }

    return $true
}

function Reset-GhAccount {
    <#
    .SYNOPSIS
        Restores the gh token and active account recorded by Use-GhAccount.
    .DESCRIPTION
        Puts back a GH_TOKEN that was already set, rather than just clearing
        ours, and switches the active account back if `gh auth login` changed
        it. Safe to call more than once, and a no-op if nothing was ever
        pushed, so it can run on both the success and failure paths.
    #>
    if (-not $script:GhStatePushed) { return }

    Write-Doing 'Releasing the borrowed gh token'
    if ($script:PriorGhToken) { $env:GH_TOKEN = $script:PriorGhToken }
    elseif ($env:GH_TOKEN) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }

    $restored = $true
    if ($script:PriorGhAccount) { $restored = Restore-GhAccount -Account $script:PriorGhAccount }
    $script:GhStatePushed = $false
    if ($restored) { Write-Done }
}

#───────────────────────────────────────────────────────────────────────────────
# Repositories
#───────────────────────────────────────────────────────────────────────────────

function New-GitHubRepo {
    <#
    .SYNOPSIS
        Creates an empty repo if it does not already exist,
        and returns its actual visibility.
    .DESCRIPTION
        An existing repo keeps whatever visibility it already has: changing
        that is not something a scaffolding re-run should do behind your back.
        settings.yml is where visibility is declared from then on.

        Returning the ACTUAL visibility rather than just the one asked for
        matters when they differ: a caller that used the requested value for
        everything downstream (LICENSE, settings.yml, a layer module) would
        build the rest of the repo around a visibility that was never real.
    .OUTPUTS
        [string] - 'Public' or 'Private', whichever the repo really is.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )

    Write-Doing "Creating repo $OwnerRepo"
    $ghArgs = @('repo', 'view', $OwnerRepo, '--json', 'visibility', '--jq', '.visibility')
    $read = Invoke-GhRead -Arguments $ghArgs
    if ($read.Ok) {
        $actual = ($read.Output -join '').Trim().ToLowerInvariant()
        $actualVisibility = if ($actual -eq 'private') { 'Private' } else { 'Public' }
        Write-Done -Skip "already exists ($actual)"
        if ($actualVisibility -ne $Visibility) {
            Write-Warn "Existing repo is $actual, but Visibility says $Visibility - using $actual"
        }

        return $actualVisibility
    }

    $flag = "--$($Visibility.ToLowerInvariant())"
    Invoke-Gh -Activity "Creating $OwnerRepo" `
        -Arguments @('repo', 'create', $OwnerRepo, $flag) | Out-Null
    Add-Change
    Write-Done "empty $($Visibility.ToLowerInvariant()) repo"
    return $Visibility
}

#───────────────────────────────────────────────────────────────────────────────
# Settings
#───────────────────────────────────────────────────────────────────────────────

function Set-WorkflowPermission {
    <#
    .SYNOPSIS
        Allows GitHub Actions to create and approve PRs,
        preserving the default permissions.
    .DESCRIPTION
        The PUT has to restate default_workflow_permissions, so the current
        value is read first and passed straight back. If it cannot be read,
        nothing is written - guessing would be a demotion.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo)

    Write-Doing 'Allowing Actions to create and approve pull requests'
    $endpoint = "repos/$OwnerRepo/actions/permissions/workflow"
    $read = Invoke-GhRead -Arguments @('api', $endpoint)
    if (-not $read.Ok) {
        # Not guessable. The PUT has to restate default_workflow_permissions,
        # and the only available guess is 'read' - which would quietly demote
        # a repo whose Actions could write.
        Register-UncheckedSetting -What 'the Actions workflow permissions' -Steps @(
            "https://github.com/$OwnerRepo/settings/actions"
            "under 'Workflow permissions', tick"
            "'Allow GitHub Actions to create and approve pull requests'"
        )

        return
    }

    # gh writes its error body to STDOUT, so even a failed GET parses - into an
    # object with message/status. Under StrictMode, reading a missing property
    # throws, so test first.
    $cur = ($read.Output -join "`n") | ConvertFrom-Json
    $props = if ($cur) { @($cur.PSObject.Properties.Name) } else { @() }
    $canApprove = $props -contains 'can_approve_pull_request_reviews' -and
        $cur.can_approve_pull_request_reviews
    if ($canApprove) {
        Write-Done -Skip 'already allowed'
        return
    }

    $perm = 'read'
    if ($props -contains 'default_workflow_permissions') {
        $perm = $cur.default_workflow_permissions
    }

    $ghArgs = @(
        'api', '--method', 'PUT', $endpoint
        '-f', "default_workflow_permissions=$perm"
        '-F', 'can_approve_pull_request_reviews=true'
    )

    Invoke-Gh -Activity 'Allowing Actions to create and approve PRs' -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Done
}

function Enable-PrivateVulnReporting {
    <#
    .SYNOPSIS
        Enables private vulnerability reporting.
    .DESCRIPTION
        No-op if already on. Tolerated rather than asserted: GitHub 422s when
        the repo is not eligible, and losing one setting should not fail an
        otherwise good run - so a failed write goes to the checklist instead.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo)

    Write-Doing 'Enabling private vulnerability reporting'
    $endpoint = "repos/$OwnerRepo/private-vulnerability-reporting"
    $read = Invoke-GhRead -Arguments @('api', $endpoint, '--jq', '.enabled')
    if ($read.Ok -and ($read.Output -join '').Trim() -eq 'true') {
        Write-Done -Skip 'already enabled'
        return
    }

    $write = Invoke-GhRead -Arguments @('api', '--method', 'PUT', $endpoint, '--silent')
    if ($write.Ok) {
        Add-Change
        Write-Done
        return
    }

    Write-Warn 'Could not enable private vulnerability reporting - added to the checklist'
    Add-ManualItem -Category $script:ManualSettingCategory `
        -Title 'Enable private vulnerability reporting' `
        -Steps @(
        "https://github.com/$OwnerRepo/settings/security_analysis"
        "enable 'Private vulnerability reporting'"
    )
}

function Set-RepoSecret {
    <#
    .SYNOPSIS
        Adds a repo secret, without ever overwriting an existing one.
    .DESCRIPTION
        A personal account cannot share an Actions secret across repos - that
        is an organization feature - so every secret is per-repo and this runs
        once per new repo.

        Never overwrites: a secret that is already there was more likely set
        deliberately than left over by mistake, and silently replacing a
        working token is worse than leaving it alone.
    .PARAMETER Name
        The secret's name, e.g. CODECOV_TOKEN.
    .PARAMETER Token
        The value. Empty warns and returns, because a missing token is a thing
        to go and do rather than a reason to fail the run.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$Name,
        [string]$Token
    )

    Write-Doing "Setting the $Name secret"

    # The listing IS the no-overwrite guarantee, so a listing that failed is
    # not permission to write - it is a reason not to.
    $read = Invoke-GhRead -Arguments @('secret', 'list', '--repo', $OwnerRepo)
    if (-not $read.Ok) {
        Register-UncheckedSetting -What "the $Name secret" -Steps @(
            "https://github.com/$OwnerRepo/settings/secrets/actions"
            "add $Name if it is not already there"
        )

        return
    }

    # Escaped: the name is a literal, and a listing is matched line by line.
    if (@($read.Output) -match "^$([regex]::Escape($Name))\b") {
        Write-Done -Skip "already set (change it with 'gh secret set')"
        return
    }

    if (-not $Token) {
        Write-Warn "$Name not provided - add it with gh secret set"
        return
    }

    # No --body: gh reads the value from stdin when it is omitted, so the
    # secret never enters the argument vector - which a failure message renders
    # in full, onto the console and into any transcript.
    $ghArgs = @('secret', 'set', $Name, '--repo', $OwnerRepo)
    Invoke-Gh -Activity "Setting the $Name secret" -Arguments $ghArgs -StdIn $Token | Out-Null
    Add-Change
    Write-Done
}

function Set-RepoVariable {
    <#
    .SYNOPSIS
        Adds a repo variable, without ever overwriting an existing one.
    .DESCRIPTION
        A variable rather than a secret, because these are switches and paths
        - things worth being able to read back. Same no-overwrite rule as
        Set-RepoSecret.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    Write-Doing "Setting the $Name variable"

    # As in Set-RepoSecret: an unreadable listing is not permission to write.
    $read = Invoke-GhRead -Arguments @('variable', 'list', '--repo', $OwnerRepo)
    if (-not $read.Ok) {
        Register-UncheckedSetting -What "the $Name variable" -Steps @(
            "https://github.com/$OwnerRepo/settings/variables/actions"
            "set $Name to '$Value' if it is not already there"
        )

        return
    }

    if (@($read.Output) -match "^$([regex]::Escape($Name))\b") {
        Write-Done -Skip "already set (change it with 'gh variable set')"
        return
    }

    # --body is fine here: a variable's value is not a secret, and seeing it in
    # a failure message is useful.
    $ghArgs = @('variable', 'set', $Name, '--repo', $OwnerRepo, '--body', $Value)
    Invoke-Gh -Activity "Setting the $Name variable" -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Done "= $Value"
}

function Initialize-Topic {
    <#
    .SYNOPSIS
        Seeds one throwaway topic, so settings.yml can manage topics after that.
    .DESCRIPTION
        The Settings app's topics call does not land on a repo that has never
        had a topic. The real list stays in settings.yml, which overwrites this
        seed on the next sync.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo)

    Write-Doing 'Seeding a topic so settings.yml can manage them'

    # PUT /topics REPLACES the whole list, so seeding on the strength of an
    # unreadable GET would discard whatever is already there. And the count
    # would be gh's error body, which [int] cannot convert - a terminating
    # cast error naming neither gh nor this repo.
    $endpoint = "repos/$OwnerRepo/topics"
    $read = Invoke-GhRead -Arguments @('api', $endpoint, '--jq', '.names | length')
    if (-not $read.Ok) {
        Register-UncheckedSetting -What 'the repo topics' -Steps @(
            "https://github.com/$OwnerRepo"
            'if it has no topics, add any one so settings.yml can manage them'
        )

        return
    }

    $current = ($read.Output -join '').Trim()
    if ($current -match '^\d+$' -and [int]$current -gt 0) {
        Write-Done -Skip "already seeded ($current) - settings.yml owns them"
        return
    }

    $ghArgs = @('api', '--method', 'PUT', $endpoint, '-f', 'names[]=github')
    Invoke-Gh -Activity 'Seeding a placeholder topic' -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Done "'github' - settings.yml replaces it on the next sync"
}

function Enable-ReleaseImmutability {
    <#
    .SYNOPSIS
        Enables immutable releases, locking assets and tags once published.
    .DESCRIPTION
        Uses the dedicated /immutable-releases endpoints; the repo PATCH
        endpoint has no field for it. Still in preview, so a failure falls back
        to the manual checklist.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo)

    Write-Doing 'Enabling immutable releases'

    # GET returns 204 when enabled and 404 when not. A non-zero exit therefore
    # means 'not enabled' OR 'could not tell' - and both are handled the same
    # way below, by trying the PUT and falling back to the checklist.
    $endpoint = "repos/$OwnerRepo/immutable-releases"
    if ((Invoke-GhRead -Arguments @('api', $endpoint, '--silent')).Ok) {
        Write-Done -Skip 'already enabled'
        return
    }

    if ((Invoke-GhRead -Arguments @('api', '--method', 'PUT', $endpoint, '--silent')).Ok) {
        Add-Change
        Write-Done
        return
    }

    Write-Warn "Couldn't enable immutable releases via the API (preview) - added to the checklist"
    Add-ManualItem -Category $script:ManualSettingCategory `
        -Title 'Enable release immutability' `
        -Steps @(
        "https://github.com/$OwnerRepo/settings  →  General"
        "check 'Enable release immutability'"
    )
}

function Get-ManualGitHubSetting {
    <#
    .SYNOPSIS
        Returns the repo settings GitHub only exposes in the web UI, as
        checklist items.
    .DESCRIPTION
        Not exported. Release immutability is deliberately absent: it has a
        real API now, and Enable-ReleaseImmutability queues it only if that
        call fails.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )

    $settings = "https://github.com/$OwnerRepo/settings"
    $security = "$settings/security_analysis"
    $items = @(
        @{
            Title = 'Limit branches/tags updated per push to 2'
            Steps = @(
                "$settings  →  General"
                "check 'Limit how many branches and tags can be updated in a single push'  →  set 2"
            )
        }

        @{
            Title = 'Restrict code review to users with read+ access'
            Steps = @(
                "$settings  →  Moderation options  →  Code review limits"
                "check 'Limit to users explicitly granted read or higher access'"
            )
        }

        @{
            Title = 'Enable grouped security updates'
            Steps = @("$security  →  enable 'Grouped security updates'")
        }
    )

    # A public repo always has the dependency graph on, with no toggle, so
    # only a private one needs asking about.
    if ($Visibility -eq 'Private') {
        $items += @{
            Title = 'Enable the Dependency graph'
            Steps = @("$security  →  enable 'Dependency graph'")
        }
    }

    return , $items
}

function Register-ManualGitHubSetting {
    <#
    .SYNOPSIS
        Queues the repo settings GitHub only exposes in the web UI (no REST
        API), plus one thing to check once the Settings app has run.
    .PARAMETER Visibility
        Decides whether the dependency graph is listed, so it changes what
        prints rather than only how it reads.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )

    foreach ($item in (Get-ManualGitHubSetting -OwnerRepo $OwnerRepo -Visibility $Visibility)) {
        Add-ManualItem -Category $script:ManualSettingCategory -Title $item.Title -Steps $item.Steps
    }

    # Its own category: the API already wrote the description and topics, so
    # this is confirming they landed, not a setting to go and change.
    Add-ManualItem -Category 'Verify once the Settings app has run' `
        -Title 'The description and topics appear on the home page' `
        -Steps @(
        "https://github.com/$OwnerRepo"
        'the Settings app applies settings.yml within a few minutes'
    )
}

function Get-ManualCiWorkflow {
    <#
    .SYNOPSIS
        Returns which of continuous-integration.yml / publish-release.yml a
        Code repo's template chain did not already provide, as checklist
        items.
    .DESCRIPTION
        Not exported. Checking whether the file already exists, rather than
        which layer is supposed to provide it, is what lets this stop
        nagging the moment a publishing template layer starts writing a
        working one of its own via its layer module - with nothing here to
        update when that happens.
    .PARAMETER RepoPath
        The new repo's own root, checked after its layer module has run.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    $items = @()

    $ciPath = Join-Path $RepoPath '.github/workflows/continuous-integration.yml'
    if (-not (Test-Path -LiteralPath $ciPath)) {
        $items += @{
            Title = 'Add a Continuous Integration workflow'
            Steps = @(
                "Build and test this repo's own code."
                "Produce a version.txt and upload a 'packages' artifact -"
                "or whatever names draft-release's build-workflow/artifact-name."
                'Via a short-lived branch and PR; rulesets require it.'
            )
        }
    }

    $publishPath = Join-Path $RepoPath '.github/workflows/publish-release.yml'
    if (-not (Test-Path -LiteralPath $publishPath)) {
        $items += @{
            Title = 'Add a Publish Release workflow, if this repo publishes anything'
            Steps = @(
                "On 'release: published', do this repo's own publish step -"
                'a feed push, an image push, move-version-aliases for floating tags.'
                'Same PR route. Skip this if there is nothing to publish.'
            )
        }
    }

    return , $items
}

function Register-ManualCiWorkflow {
    <#
    .SYNOPSIS
        Queues adding continuous-integration.yml / publish-release.yml, for
        whichever of the two this repo's template chain did not already
        provide.
    .PARAMETER RepoPath
        The new repo's own root, checked after its layer module has run.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    foreach ($item in (Get-ManualCiWorkflow -RepoPath $RepoPath)) {
        Add-ManualItem -Category "Add this repo's own release workflows" `
            -Title $item.Title -Steps $item.Steps
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Code scanning
#───────────────────────────────────────────────────────────────────────────────

function Add-CodeqlLanguage {
    <#
    .SYNOPSIS
        Registers CodeQL languages for this layer, adding to the inherited list.
    .PARAMETER Language
        One or more of: actions, c-cpp, csharp, go, java-kotlin,
        javascript-typescript, python, ruby, swift. Anything else throws.
    #>
    param([Parameter(Mandatory)][string[]]$Language)

    foreach ($lang in $Language) {
        $l = $lang.Trim()
        if ($l -notin $script:CodeqlValidLanguages) {
            throw ("'$l' is not a CodeQL language. Valid values: " +
                ($script:CodeqlValidLanguages -join ', '))
        }

        if ($script:CodeqlLanguages.Add($l)) { Write-Detail "CodeQL will analyse '$l'" }
    }
}

function Get-CodeqlSetup {
    <#
    .SYNOPSIS
        Reads the repo's current CodeQL default setup.
    .DESCRIPTION
        Not exported. One call, not two: read separately, a failed language
        read beside a successful state read would report 'configured' with no
        languages, and the caller would then PATCH that - dropping whatever
        somebody had enabled by hand.

        Ok is false only when the endpoint could not be read at all. A repo
        with no setup yet answers non-zero too, so that case is reported as
        Ok with an empty state rather than as a failure.
    .OUTPUTS
        [hashtable] @{ Ok; State; Languages }
    #>
    param([Parameter(Mandatory)][string]$Endpoint)

    $jq = '(.state // "") + "|" + ((.languages // []) | join(","))'
    $read = Invoke-GhRead -Arguments @('api', $Endpoint, '--jq', $jq)
    $raw = ($read.Output -join '').Trim()

    # Not configured yet: gh exits non-zero with a 404 body. That is an answer,
    # so it reads as Ok with nothing set.
    if (-not $read.Ok) {
        $notFound = ($raw -match '(?i)\bnot found\b|"status"\s*:\s*"404"')
        return @{ Ok = $notFound; State = ''; Languages = @() }
    }

    # Typed, and not an if-expression: one that emits a single language would
    # unroll it to a string, and one that emits an empty array would leave the
    # variable $null - either breaks the -notin comparisons downstream.
    $parts = $raw -split '\|', 2
    [string[]]$languages = @()
    if ($parts.Count -gt 1 -and $parts[1]) {
        $languages = $parts[1] -split ',' |
            Where-Object { $_ }
    }

    return @{ Ok = $true; State = $parts[0]; Languages = $languages }
}

function Set-CodeqlSetup {
    <#
    .SYNOPSIS
        Turns on CodeQL default setup, and returns whether it took.
    .DESCRIPTION
        Not exported. PATCH, not PUT: GitHub does not route PUT here and
        answers with a bare, generic 404. Passing no -Language lets GitHub
        choose, which is the fallback when an explicit list is rejected.

        Never throws. Failure is a legitimate outcome the caller decides
        about.
    #>
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [string[]]$Language = @()
    )

    $ghArgs = @('api', '--method', 'PATCH', $Endpoint, '-f', 'state=configured')
    foreach ($l in $Language) { $ghArgs += @('-f', "languages[]=$l") }
    return (Invoke-GhRead -Arguments ($ghArgs + '--silent')).Ok
}

function Get-CodeqlTargetLanguage {
    <#
    .SYNOPSIS
        Returns the languages CodeQL should end up analysing: what it already
        does, plus everything the chain registered.
    .DESCRIPTION
        Not exported. What is already configured is always kept, so a language
        enabled by hand is never removed. Sorted, so the list reads the same
        whichever layer added what.
    #>
    param([AllowEmptyCollection()][string[]]$Current = @())

    $wanted = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$Current, [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($l in $script:CodeqlLanguages) { [void]$wanted.Add($l) }
    return , @($wanted | Sort-Object)
}

function Write-CodeqlOutcome {
    <#
    .SYNOPSIS
        Reports which languages CodeQL actually ended up analysing.
    .DESCRIPTION
        Not exported. Only needed after the fallback, where GitHub decided the
        list instead of us: what was asked for and what landed can differ, and
        the difference is worth saying out loud.
    #>
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [string[]]$Wanted = @(),
        [string[]]$Before = @()
    )

    $after = Get-CodeqlSetup -Endpoint $Endpoint
    if (-not $after.Ok) {
        Add-Change
        Write-Done 'enabled'
        Write-Detail 'could not read back which languages it chose'
        return
    }

    $now = @($after.Languages)
    $nowList = ($now | Sort-Object) -join ', '

    # Nothing new reports a skip, which keeps the change count at zero for an
    # already-scaffolded repo.
    $fresh = @($now | Where-Object { $_ -notin $Before })
    if ($fresh -or -not $Before) {
        Add-Change
        Write-Done "enabled: $nowList"
    }
    else {
        Write-Done -Skip "already analysing: $nowList"
    }

    $missing = @($Wanted | Where-Object { $_ -notin $now })
    if ($missing) {
        Write-Detail "not in the repo yet, so not enabled: $($missing -join ', ')"
        Write-Detail 're-run once that code exists to add them'
    }
}

function Register-CodeqlSetupItem {
    <#
    .SYNOPSIS
        Queues CodeQL setup on the manual checklist.
    .DESCRIPTION
        Not exported. Code scanning can be unavailable on a repo that is only
        seconds old, so this is handed to the checklist rather than failing the
        run - and a later re-run picks it up on its own.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo)

    Write-Warn 'CodeQL default setup not enabled automatically - added to the checklist'
    Add-ManualItem -Category $script:ManualSettingCategory `
        -Title 'Set up CodeQL default analysis' `
        -Steps @(
        "https://github.com/$OwnerRepo/settings/security_analysis"
        'Code scanning  →  Default  →  Enable'
        'Or just re-run this script once the repo is a few minutes old.'
    )
}

function Enable-Codeql {
    <#
    .SYNOPSIS
        Enables CodeQL default setup for every language the chain registered.
    .DESCRIPTION
        Languages come from Add-CodeqlLanguage. Call this AFTER the first push
        - the repo needs content.

        Unlike the other settings helpers, this does NOT simply skip when
        already configured: a layer may have added a language since, so it
        extends the existing list instead. What is already configured is
        always kept, so a language enabled by hand is never removed.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo)

    Write-Doing 'Enabling CodeQL default setup'
    $endpoint = "repos/$OwnerRepo/code-scanning/default-setup"
    $current = Get-CodeqlSetup -Endpoint $endpoint
    if (-not $current.Ok) {
        # The PATCH replaces the language list, so writing one built from a
        # read that failed would drop anything enabled by hand.
        Register-CodeqlSetupItem -OwnerRepo $OwnerRepo
        return
    }

    $langs = Get-CodeqlTargetLanguage -Current $current.Languages
    $added = @($langs | Where-Object { $_ -notin $current.Languages })
    if ($current.State -eq 'configured' -and -not $added) {
        Write-Done -Skip "already analysing: $($langs -join ', ')"
        return
    }

    if (Set-CodeqlSetup -Endpoint $endpoint -Language $langs) {
        Add-Change
        Write-Done "enabled: $($langs -join ', ')"
        return
    }

    # GitHub 422s on a language the repo does not contain - expected for a
    # template that declares csharp before it has any C#. Retry without the
    # list, and let GitHub enable whatever is actually there.
    if (Set-CodeqlSetup -Endpoint $endpoint) {
        Write-CodeqlOutcome -Endpoint $endpoint -Wanted $langs -Before $current.Languages
        return
    }

    Register-CodeqlSetupItem -OwnerRepo $OwnerRepo
}

Export-ModuleMember -Function @(
    'Invoke-Gh'
    'Invoke-GhRead'
    'Get-RepoOwner'
    'Use-GhAccount'
    'Reset-GhAccount'
    'New-GitHubRepo'
    'Set-WorkflowPermission'
    'Enable-PrivateVulnReporting'
    'Set-RepoSecret'
    'Set-RepoVariable'
    'Initialize-Topic'
    'Enable-ReleaseImmutability'
    'Register-ManualGitHubSetting'
    'Register-ManualCiWorkflow'
    'Add-CodeqlLanguage'
    'Enable-Codeql'
)
