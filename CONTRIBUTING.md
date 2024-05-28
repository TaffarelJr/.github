# Contributing <!-- omit from toc -->

First of all, thanks so much for your interest!
You can contribute to this project with issues and PRs.
Simply filing issues for problems you encounter is a great way to contribute.
Contributing implementations is greatly appreciated.

Table of Contents:

- [Reporting Issues](#reporting-issues)
  - [Finding Existing Issues](#finding-existing-issues)
  - [Writing a Good Bug Report](#writing-a-good-bug-report)
    - [Why are Minimal Reproductions Important?](#why-are-minimal-reproductions-important)
    - [Are Minimal Reproductions Required?](#are-minimal-reproductions-required)
    - [How to Create a Minimal Reproduction](#how-to-create-a-minimal-reproduction)
- [Contributing Changes](#contributing-changes)
  - [Quick Code Review Rules](#quick-code-review-rules)
  - [Pull Request Ownership](#pull-request-ownership)
  - [Merging Pull Requests](#merging-pull-requests)
  - [Blocking Pull Request Merging](#blocking-pull-request-merging)
  - [DOs and DON'Ts](#dos-and-donts)
  - [Suggested Workflow](#suggested-workflow)
  - [Commit Messages](#commit-messages)
  - [Vertical Rulers](#vertical-rulers)

## Reporting Issues

Bug reports, feature proposals, and overall feedback are always welcome.
Here are a few tips on how you can make reporting your issue as effective
as possible.

### Finding Existing Issues

Before filing a new issue, please check if one already exists on that topic.
If you do find an existing issue, please include your own feedback
in the discussion. Do consider upvoting (👍 reaction) the original post,
as this helps with prioritizing popular issues in the backlog.

### Writing a Good Bug Report

Good bug reports make it easier to verify and root cause the underlying problem.
The better a bug report, the faster the problem will be resolved.
Ideally, a bug report should contain the following information:

- A high-level description of the problem.
- A _minimal reproduction_, i.e. the smallest size of code/configuration
  required to reproduce the wrong behavior.
- A description of the _expected behavior_,
  contrasted with the _actual behavior_ observed.
- Information on the environment: OS/distro, CPU arch, package version, etc.
- Additional information, e.g. Is it a regression from previous versions?
  Are there any known workarounds?

#### Why are Minimal Reproductions Important?

A reproduction helps verify the presence of a bug,
and diagnose the issue using a debugger.
A _minimal_ reproduction is the smallest possible console application
demonstrating that bug. Minimal reproductions are generally preferable since they:

1. Focus debugging efforts on a simple code snippet,
2. Ensure that the problem is not caused by unrelated dependencies/configuration,
3. Avoid the need to share production codebases.

#### Are Minimal Reproductions Required?

In certain cases, creating a minimal reproduction might not be practical
(e.g. due to nondeterministic factors, external dependencies).
In such cases you would be asked to provide as much information as possible.
If the root cause of the problem is not able to be determined,
the issue might be closed as "not actionable."
While not required, minimal reproductions are strongly encouraged and will
significantly improve the chances of an issue being prioritized and fixed.

#### How to Create a Minimal Reproduction

The best way to create a minimal reproduction is
gradually removing code and dependencies from a reproducing app,
until the problem no longer occurs. A good minimal reproduction:

- Excludes all unnecessary types, methods, code blocks, source files,
  nuget dependencies and project configurations.
- Contains documentation or code comments illustrating expected
  vs actual behavior.
- If possible, avoids performing any unneeded IO or system calls.
  For example, can the ASP.NET based reproduction be converted
  to a plain old console app?

## Contributing Changes

Changes will be merged if they improve the project in some way.
All contributions are made via
[pull requests (PRs) from forks of the repo](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/creating-a-pull-request-from-a-fork)
rather than through direct commits or PRs from branches in the repo.
The pull requests are merged after review and approval from a code owner.

### Quick Code Review Rules

- Do not mix unrelated changes in one pull request.
  For example, a code style change should never be mixed with a bug fix.
- All changes should follow the existing code style.
  This is enforced by the analyzers and style rules embedded in the project.
  They should be picked up by your IDE: address any warnings before submitting.
- Use Draft pull requests for changes you are still working on
  but want early CI loop feedback.
  When you think your changes are ready for review,
  [change the status](https://help.github.com/en/github/collaborating-with-issues-and-pull-requests/changing-the-stage-of-a-pull-request)
  of your pull request.
- Rebasing is encouraged, to keep a clean history of changes.

### Pull Request Ownership

The code owners of the project have the final say when it comes to
style, merge, or other conflicts. While a PR may satisfy all the technical
requirements, a code owner may still make or request additional changes
if they feel it necessary to maintain project consistency and/or integrity.
Code owners reserve the right to alter the code and/or commits in a PR
themselves before approving and merging it.

### Merging Pull Requests

Pull request can be merged when the following conditions have been met:

- The PR has been approved by at least one code owner
  and any other objections are addressed.
  - You can request another review from the original reviewer.
- The PR successfully builds and passes all tests in the
  Continuous Integration (CI) system.

### Blocking Pull Request Merging

If for whatever reason you would like to move your pull request
back to an in-progress status to avoid merging it in the current form, you can
turn the PR into a draft PR by selecting the option under the reviewers section.
Alternatively, you can do that by adding [WIP] prefix to the pull request title.

### DOs and DON'Ts

Please do:

- **DO** follow the coding style configured in the project.
- **DO** give priority to the current style of the project or file you're
  changing, even if it diverges from the general configuration.
- **DO** include tests when adding new features. When fixing bugs, start with
  adding a test that highlights how the current behavior is broken.
- **DO** keep discussions focused. When a new or related topic comes up,
  it's often better to create a new issue than to side-track the discussion.
- **DO** clearly state in an issue if you are going to take on implementation.
- **DO** blog and tweet (or whatever) about your contributions, frequently!

Please do not:

- **DON'T** just submit big pull requests.
  Instead, file an issue and start a discussion
  so we can agree on a direction before you invest a large amount of time.
- **DON'T** commit code that you didn't write.
  If you find code that you think is a good fit to add to the project,
  file an issue and start a discussion before proceeding.

### Suggested Workflow

The following workflow is recommended:

1. Create an issue for your work.
   - You can skip this step for trivial changes.
   - Reuse an existing issue on the topic, if there is one.
   - Get agreement from the code owners that your proposed change is a good one.
   - Clearly state that you're taking on the implementation, if that's the case.
     You can request that the issue be assigned to you.
     Note: The issue filer and the implementer don't have to be the same person.
2. Create a personal fork of the repository on GitHub
   (if you don't already have one).
3. In your fork, create a branch off of **main** (`git checkout -b mybranch`).
   - Name the branch so that it clearly communicates your intentions,
     such as **issue-123** or **githubhandle-issue**.
   - Branches are useful since they isolate your changes
     from incoming changes from upstream.
     They also enable you to create multiple PRs from the same fork.
4. Make and commit your changes to your branch.
   - Please follow our [Commit Messages](#commit-messages) and
     [Vertical Rulers](#vertical-rulers) guidance.
5. Add new tests corresponding to your change, if applicable.
6. Build the repository with your changes.
   - Make sure that the builds are clean.
   - Make sure that the tests are all passing, including your new tests.
7. Create a pull request (PR) against the original repository's **main** branch.
   - State in the description what issue or improvement your change is addressing.
   - Check if all the Continuous Integration checks are passing.
8. Wait for feedback or approval of your changes from the code owners.
9. When code owners have signed off, and all checks are green,
   the PR will be merged.
   - The next official build will automatically include your change.
   - You can delete the branch you used for making the change.

### Commit Messages

This repo uses [Conventional Commits](https://www.conventionalcommits.org)
to standardize the format of commit messages. This enables the automation of
things like versioning and the generation of changelogs & release notes.
If you're new to or unfamiliar with Conventional Commits, this
[Cheat sheet](https://kapeli.com/cheat_sheets/Conventional_Commits.docset/Contents/Resources/Documents/index)
by Bogdan Popescu can help with the basics.

To facilitate this, a default Git message template is included.
You can activate it by running the following command from the repo root:

```cmd
git config commit.template .gitmessage
```

Afterward, whenever you run `git commit` (without `-m`) the template should be
displayed in your configured text editor.
Simply fill in the details and save the commit message.

Also, do your best to factor commits appropriately:
not too large with unrelated things in the same commit,
and not too small with the same small change applied N times in N different commits.

### Vertical Rulers

In order to facilitate side-by-side code comparisons,
this project encourages lines of code to be kept relatively short:

- **80 characters** is the ideal limit.
  Wrap lines of code by this point as often as possible.
- **100 characters** can be acceptable if the code doesn't change often,
  is common boilerplate, or is aesthetically more pleasing.
- **120 characters** is the absolute maximum. Do not extend beyond this length
  unless there is no choice (e.g., a long URL link in a Markdown file).

To facilitate this, it's recommended to display vertical rulers in your IDE
of choice:

- **Visual Studio**: Install the
  [Editor Guidelines](https://marketplace.visualstudio.com/items?itemName=PaulHarrington.EditorGuidelinesPreview)
  extension. Vertical rulers are already defined in the solution,
  and should display upon reopening it.

- **Visual Studio Code**: In Settings, search for "Rulers" and add the following:
  ```json
  "editor.rulers": [
    { "column": 80, "color": "#00ff0050" },
    { "column": 100, "color": "#ffff0075" },
    { "column": 120, "color": "#8b0000ff" }
  ],
  ```
