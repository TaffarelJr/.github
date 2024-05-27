# `.github` Repository <!-- omit from toc -->

This is a special, base template repository that contains
default [community health files][health], [templates][templates],
[workflows][workflows], and any other files
to be shared with derived repositories.
For more information on how this special repository works,
see this article on [freeCodeCamp][freeCodeCamp].

```mermaid
---
title: Personal GitHub Repository Structure
---

flowchart TB

  subgraph subGH [" "]
    gh(**.github**
    repository)

    noteGH[This contains core files to
    be referenced by or synced
    to all my other repos.]
  end

  subgraph subT [" "]
    T1(**.template-&lt;type&gt;**
    repository)

    T2(**.template-&lt;type&gt;**
    repository)

    noteT[These define more specific
    default files and structures
    for different repo types.]
  end

  subgraph subR [" "]
    R1(**&lt;name&gt;**
    repository)

    R2(**&lt;name&gt;**
    repository)

    R3(**&lt;name&gt;**
    repository)

    R4(**&lt;name&gt;**
    repository)

    noteR[These are the actual repos
    where my projects live.]
  end

  classDef current fill:#E68A39,color:#000000
  class gh current

  classDef sub opacity:0
  class subGH,subT,subR sub

  classDef note fill:#FFFFDD,color:#000000
  class noteGH,noteT,noteR note

  gh --> T1
  gh --> T2

  T1 --> R1
  T1 --> R2
  T2 --> R3
  T2 --> R4
```

#### Table of Contents <!-- omit from toc -->

- [Description of Files in This Template Repo](#description-of-files-in-this-template-repo)
  - [Community Health Files](#community-health-files)
  - [Other Files](#other-files)

## Description of Files in This Template Repo

### [Community Health Files][health]

| File                         | Exists only</br>in this repo | Synced to<br/>(and overridden in)<br/>derived repos | Notes      |
| :--------------------------- | :--------------------------: | :-------------------------------------------------: | :--------- |
| [`CODE_OF_CONDUCT.md`][coc]  |              ✅              |                                                     |            |
| [`CONTRIBUTING.md`][contrib] |                              |                         ✅                          |            |
| [`FUNDING.yml`][funding]     |              ✅              |                                                     |            |
| `GOVERNANCE.md`              |                              |                                                     | Not needed |
| [`SECURITY.md`][security]    |                              |                         ✅                          |            |
| [`SUPPORT.md`][support]      |                              |                         ✅                          |            |

### Other Files

| File                            | Exists only</br>in this repo | Synced to<br/>(and overridden in)<br/>derived repos | Purpose                                     |
| :------------------------------ | :--------------------------: | :-------------------------------------------------: | :------------------------------------------ |
| [`.editorconfig`][editorConfig] |                              |                         ✅                          | [Style guide rule definitions][styleGuides] |
| [`.gitmessage`][message]        |                              |                         ✅                          | [Commit message template][messageGuide]     |
| [`docs/`][docs]                 |                              |                         ✅                          | Contains documentation                      |

<!-- Source Code URIs -->

[coc]: ./CODE_OF_CONDUCT.md
[contrib]: ./CONTRIBUTING.md
[docs]: ./docs/
[editorConfig]: ./.editorconfig
[funding]: ./.github/FUNDING.yml
[message]: ./.gitmessage
[messageGuide]: ./docs/StyleGuides.md#commit-messages
[security]: ./SECURITY.md
[styleGuides]: ./docs/StyleGuides.md
[support]: ./SUPPORT.md

<!-- Public URIs -->

[freeCodeCamp]: https://www.freecodecamp.org/news/how-to-use-the-dot-github-repository
[health]: https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file
[templates]: https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/configuring-issue-templates-for-your-repository
[workflows]: https://docs.github.com/en/actions/how-tos/writing-workflows
