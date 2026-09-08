# Scripts <!-- omit from toc -->

`New-Repo.ps1` creates a repo **derived from the template repo it runs in**:
either a new **template layer** or a **code repo** (a leaf).
It creates the repo on GitHub, clones it next to this one,
rewrites the inherited files into the new repo's own,
and hands over a working tree that is committed, pushed and syncing.

#### Table of Contents <!-- omit from toc -->

- [Running it](#running-it)
- [What a run does](#what-a-run-does)
- [What is in this folder](#what-is-in-this-folder)
- [Adding a layer](#adding-a-layer)
- [Tests](#tests)

## Running it

You need PowerShell 7, `git`, and `gh` logged in to an account
with admin access to the new repo's owner.

```powershell
./scripts/New-Repo.ps1
```

There are no command-line parameters. Every value is prompted for —
kind, name, visibility, description, homepage, topics —
with a default where one makes sense (press ENTER to take it),
and a confirmation before anything is created.
A bad answer is explained and asked again.

The one exception is the three secret tokens.
Each is read from the **environment variable of the same name** first —
`CODECOV_TOKEN`, `COPILOT_PAT`, `TEMPLATE_SYNC_PAT` —
and only prompted for when that is unset.
Set them once as user environment variables and they are never asked for again.
Leave one blank to skip it; the run says what that costs.

The GitHub owner is a constant (`$script:RepoOwner` in `Common-GitHub.psm1`):
this scaffolding is personal-only, and it warns if the repo's `origin` disagrees.

Start from a clean tree. Scaffolding stages by pathspec, so a file you have
merely modified is left alone — but anything already `git add`ed goes in with
the next commit.

## What a run does

Each step verifies what is already done and only fills the gaps,
so re-running on the same repo is safe: an existing repo is not recreated,
the clone is reused rather than reset, and a commit already in the history is
skipped. A run that dies partway leaves a marker under `.git/new-repo-gate/`
and resumes from it next time. A fully scaffolded repo is a no-op.

1. Create the repo on GitHub, public or private.
2. Apply the settings the API can reach: workflow permissions, private
   vulnerability reporting, release immutability, a placeholder topic, the
   secrets, and the two Template Sync variables. Anything refused goes on the
   checklist instead.
3. Clone it, with `origin` and a `template` remote pointing at this repo.
4. `chore: remove template-only files` — the files that belong only to the base
   repo, and their rows in the README. A code repo also loses `scripts/` and
   gets an ordinary project README.
5. `chore: retarget template references` — `owner/parent` becomes
   `owner/this-repo` in the community files and issue forms; the README
   diagram highlights the template row; a template's README is retitled.
6. Each layer's own commits, from every `New-Repo-<NN>-<slug>.psm1` in this
   folder, in tier order.
7. `chore: customize repo settings` — `.github/settings.yml` with
   `_extends: <parent>` (and `is_template: false` for a code repo), plus an
   all-rights-reserved `LICENSE` for a private repo.
8. Push, then enable CodeQL for every language the chain registered.
9. Dispatch Template Sync and confirm it ran clean with no pull request.
10. Write a `<repo>.code-workspace` holding the new repo and every layer of its
    chain that is cloned locally, and open it in VS Code.

It then prints a **checklist** of the settings that have no API —
per-push limits, code review limits, grouped security updates,
and the dependency graph on a private repo —
to do by hand in the web UI.

Scaffolding stops there. Repo-specific customizations are ordinary commits
you make afterwards, on a branch, as a pull request — which the rulesets
require anyway once the Settings app has applied them.

## What is in this folder

Every file is named for what it is, so the folder reads without opening anything:

```text
Common-<Concern>.psm1             shared by any entry script here
<Entry-Script>.ps1                an entry point
<Entry-Script>-<Part>.psm1        a module only that script uses
<Entry-Script>-<NN>-<slug>.psm1   one layer's additions, run in tier order
tests/<Module>.Tests.ps1          that module's tests, one file per module
```

**Nothing is imported by name.** An entry script loads every `.psm1` beside
it by pattern, except the tier-numbered layer modules, which
`Common-Plugin.psm1` loads afterwards in tier order.
Modules never import a sibling: they find each other by name at call time,
so a new `Common-*.psm1` is picked up by being dropped in.

Everything here except a layer's own `New-Repo-<NN>-<slug>.psm1`
(and its test file) is **inherited verbatim** by every layer below.
Edit those files in `.github` and let Template Sync carry the change down;
a per-layer edit conflicts on every future sync.
[Template Chain][chainFile] has the ownership rules.

## Adding a layer

A template layer contributes one **additive** module, never an edit:

```powershell
# .template-dotnet/scripts/New-Repo-10-dotnet.psm1
function Rename-DotnetProject { param($RepoPath, $To) ... }

function Invoke-DotnetScaffold {
    param([hashtable]$Context)   # RepoPath, RepoName, Kind, OwnerRepo,
                                 # SourceOwnerRepo, Description, Homepage,
                                 # Topics, Visibility
    Invoke-GatedCommit -RepoPath $Context.RepoPath `
        -Message 'chore: rename the placeholder project' `
        -Body { Rename-DotnetProject -RepoPath $Context.RepoPath -To $Context.RepoName }
}

Export-ModuleMember -Function Rename-DotnetProject, Invoke-DotnetScaffold
```

- The tier is **exactly two digits**, and fixes the order the layers run in.
  Two layers on one tier throw; a one- or three-digit tier is refused.
- The entry point is whichever exported function matches `Invoke-*Scaffold`.
  None is fine — a layer may contribute helpers only. Two throw.
- Helpers are visible to every layer below, so a child can call a parent's.
- **A layer commits its own work** through `Invoke-GatedCommit`, one commit per
  concern. `-Paths` is optional: without it, whatever the body dirtied is what
  gets staged. Changes left uncommitted are warned about, and lost.
- The layers that run are the **source** template's — the repo `New-Repo.ps1`
  runs from — so a leaf still gets its ancestors' work even though its own
  `scripts/` is deleted.
- Put its tests in `tests/New-Repo-<NN>-<slug>.Tests.ps1`.
  The runner picks the file up by pattern.

## Tests

```powershell
./scripts/tests/Run-Tests.ps1                    # everything, about two minutes
./scripts/tests/Run-Tests.ps1 -Filter Common-Git  # one module
./scripts/tests/Run-Tests.ps1 -ShowOutput         # every file's own output
```

Each `*.Tests.ps1` runs in its own PowerShell process on the shared
`TestKit.psm1` harness, so module state and the `gh` and `Read-Host` stubs
never leak between files. `Common-Git` is the slow one: it drives real
`git` repos, because nothing else can vouch for what git does.

The [Test Scripts][testWorkflow] workflow runs the same suite on Ubuntu and
Windows for every pull request that touches `scripts/`.

<!-- Source Code URIs (folders first, then files; each alphabetical) -->

[testWorkflow]: ../.github/workflows/test-scripts.yml
[chainFile]: ../docs/TemplateChain.md
