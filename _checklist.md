# Creating a New Template Repo <!-- omit in toc -->

Template repos use the [.github][ghTemplate] repo as their base template.
Follow these steps to create a new template repo derived from it.

#### Table of Contents <!-- omit in toc -->

- [1. Create the new repo](#1-create-the-new-repo)
- [2. Configure manual repo settings](#2-configure-manual-repo-settings)
- [3. Clone the new repo](#3-clone-the-new-repo)
- [4. Customize template files](#4-customize-template-files)
- [5. Customize root files](#5-customize-root-files)
- [6. Customize repo settings](#6-customize-repo-settings)
- [7. Push changes to GitHub](#7-push-changes-to-github)
- [8. Initialize workflows](#8-initialize-workflows)

## 1. Create the new repo

- DO NOT use a template in GitHub when creating the new repo;
  we'll use Git merge to get the necessary files instead
- Always use kebab-case for the repo name
  - Use the format: `.template-<type>`
- Leave the description blank
- Don't add any files to the new repo; leave it empty

## 2. Configure manual repo settings

Not all repo settings can be managed from [settings.yml][settingsFile].
The following must be configured manually:

- Go to `Settings`
  - Go to `General`
    - Check `Enable release immutability`
    - Check `Limit how many branches and tags can be updated in a single push`
      - Up to `2` branches and tags can be updated in a push
  - Go to `Moderation options`
    - Go to `Code review limits`
      - Check `Limit to users explicitly granted read or higher access`
  - Go to `Actions`
    - Go to `General`
      - Check `Allow GitHub Actions to create and approve pull requests`
      - Click `Save`
  - Go to `Advanced Security`
    - Enable `Private vulnerability reporting`
    - Enable `Dependency graph` _(if necessary)_
    - Enable `Grouped security updates`
    - Set up `CodeQL analysis` to use `Default` settings
  - Go to `Secrets and variables`
    - Go to `Actions`
      - Add a repo secret called `CODECOV_TOKEN`
        (get the value from [Codecov][codecovToken])

## 3. Clone the new repo

Clone the new repo locally and open it in Visual Studio Code.
The .github repo needs to be added as an upstream remote
so the template sync workflow can merge its commits into the new template repo.
Execute the following commands:

```bash
# May need to configure SSH key before executing this
git config remote.pushdefault origin
git remote add template git@github.com:TaffarelJr/.github.git
git fetch template
git checkout -B main template/main
git config commit.template .gitmessage
```

## 4. Customize template files

Some files that were synced from the [.github][ghTemplate] repo
need to be customized for the new repo:

- Delete the following files that will
  reside only in the [.github][ghTemplate] repo:
  - ./.github/ISSUE_TEMPLATE/config.yml
  - ./.github/FUNDING.yml
  - Remove any mentions of them in [README.md][readmeFile] as well
- Find all instances of `TaffarelJr/.github` in the template repo
  - Replace with `TaffarelJr/<template repo name>` in **ONLY** these files:
    - [ISSUE_TEMPLATE/\*][issueFormsFolder]
    - [CONTRIBUTING.md][contribFile]
    - [SECURITY.md][securityFile]
    - [SUPPORT.md][supportFile]
- Uncomment the cron schedule in the [Template Sync][syncFile] workflow
- Make any additional changes to the template files as necessary
- Commit the changes, using the following commit message:

  ```bash
  git commit -m 'chore: customize template files'
  ```

## 5. Customize root files

Now add deeper customization to the root files
to meet the needs of the new template repo:

- Add any additional ecosystems to [dependabot.yml][dependabotFile]
- Modify [\_checklist.md][checklistFile] as needed
- Modify [.editorconfig][editorConfigFile] as needed
- Modify [.gitattributes][gitAttributesFile] as needed
  (using [scaffolding][ghGitAttributes])
- Modify [.gitignore][gitIgnoreFile] as needed
  (using [scaffolding][ghGitIgnore])
- Modify [README.md][readmeFile] as needed
- Make any additional changes to the root files as necessary
- Commit the changes, using the following commit message:

  ```bash
  git commit -m 'chore: customize root files'
  ```

## 6. Customize repo settings

Most settings in [settings.yml][settingsFile]
are fine to be inherited from the [.github][ghTemplate] repo.
Only a few need to be overridden in the new repo.

- Replace the contents of the file with the following,
  filling in the values as indicated:

  ```yml
  _extends: .github

  repository:
    #─────────────────────────────────────────────────────────────────────────────
    # "About" section (on Home Page)
    # https://github.com/repository-settings/app/blob/master/docs/plugins/repository.md
    # https://docs.github.com/en/rest/repos/repos#update-a-repository
    #─────────────────────────────────────────────────────────────────────────────

    # A short description of the repo
    # MUST BE A SINGLE LINE
    description: <1-line description>

    # A URL with more information about the repo
    homepage: <URI, if applicable; otherwise, delete this property>

    # A comma-separated list of topics to set on the repo
    # See https://github.com/topics
    topics: <topic 1>, <topic 2>, ...

    #─────────────────────────────────────────────────────────────────────────────
    # Settings → General
    # https://github.com/repository-settings/app/blob/master/docs/plugins/repository.md
    # https://docs.github.com/en/rest/repos/repos#update-a-repository
    #─────────────────────────────────────────────────────────────────────────────

    # The name of the repo
    name: <name>
  ```

- Make any additional changes as needed
- Commit the changes, using the following commit message:

  ```bash
  git commit -m 'chore: customize repo settings'
  ```

## 7. Push changes to GitHub

Push the branch to GitHub:

```bash
git push
```

The settings should take effect within a few minutes.
Verify that the new repo description and topics appear on the home page.

## 8. Initialize workflows

Go to the GitHub website and execute the following workflows
(on the `main` branch) to verify they work and to initialize their baselines:

- `Template Sync`
  - The process should complete without errors,
    and without creating a Pull Request.

<!-- Source Code URIs (alphabetical by file hierarchy) -->

[issueFormsFolder]: ./.github/ISSUE_TEMPLATE/
[syncFile]: ./.github/workflows/template-sync.yml
[dependabotFile]: ./.github/dependabot.yml
[settingsFile]: ./.github/settings.yml
[checklistFile]: ./_checklist.md
[editorConfigFile]: ./.editorconfig
[gitAttributesFile]: ./.gitattributes
[gitIgnoreFile]: ./.gitignore
[contribFile]: ./CONTRIBUTING.md
[readmeFile]: ./README.md
[securityFile]: ./SECURITY.md
[supportFile]: ./SUPPORT.md

<!-- GitHub Repo URIs (alphabetical by name) -->

[ghGitAttributes]: https://github.com/gitattributes/gitattributes
[ghGitIgnore]: https://github.com/github/gitignore
[ghTemplate]: https://github.com/TaffarelJr/.github

<!-- Public URIs (alphabetical by name) -->

[codecovToken]: https://app.codecov.io/account/gh/TaffarelJr/org-upload-token
