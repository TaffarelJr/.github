# Instructions for Copilot

## Coding Standards and Conventions

- Follow existing patterns, code styles, spacing, and naming conventions first.
- Follow instructions in code comments where found.
- Follow the [Style Guides](../docs/StyleGuides.md) for the specific language.
  - Pay special attention to the guides about security and performance.
- Keep lines short, following the [Vertical Ruler](../docs/VerticalRuler.md) document.
- In Markdown, footnotes are preferred for URLs to keep text lines short.
- Use [Conventional Commits](../docs/ConventionalCommits.md) for commit messages.
  - We use a custom `infra` type for things like Terraform changes.

## Branching and Feature Development

When implementing a new feature, always make sure the branch isn't `main`.
If it is, create a new feature branch and switch to it before making any changes.
Name the branch descriptively (e.g., `awesome-feature-name`).
The feature name should be concise and describe what is being implemented.
