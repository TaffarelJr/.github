# Style Guides <!-- omit from toc -->

This document outlines the coding standards and style guides
for contributing to this project.
Following these guidelines ensures consistency across the codebase,
improves maintainability, and makes collaboration more efficient
for all contributors.

#### Table of Contents <!-- omit from toc -->

- [Line Length and Readability](#line-length-and-readability)
- [Analyzers and Formatters](#analyzers-and-formatters)
- [Code Style](#code-style)
- [Naming Conventions](#naming-conventions)
- [Code Comments](#code-comments)
- [Documentation](#documentation)
- [Error Handling](#error-handling)
- [Security](#security)
- [Performance](#performance)
- [Testing](#testing)
- [Commit Messages](#commit-messages)

## Line Length and Readability

This project encourages keeping code lines relatively short
to facilitate side-by-side comparisons and enhance readability.
See the [Vertical Rulers][rulers] document for details
on the recommended line lengths and how to configure your IDE.

## Analyzers and Formatters

This project uses a combination of tools to enforce rules
concerning files and their contents:

- The `.gitattributes` file is responsible for low-level file concerns
  such as encoding and line-endings, so they can differ
  as needed to match to the user's machine and OS.
- The `.editorconfig` file is responsible for generic style rules
  to be enforced across all files.
  - Some IDEs have this functionality built-in, and some require a plugin.
    [Check the website][editorConfig] to see how to configure your environment.
- Additional code analyzers installed in a given project
  might require their own configuration files in addition to the ones above.
  (e.g., `.eslintrc`, `.prettierrc`, `StyleCop.json`, etc.)
  These should _defer to_ (and not conflict with) the previous tools
  and will only be added as needed.

Make sure to address any errors, warnings, or messages
before submitting a Pull Request.

## Code Style

Beyond the required styling rules enforced above,
try to simply follow any existing style in the code
and focus on making it as readable as possible:

- Functions should be small.
- Classes should be focused and cohesive.
- Follow the [SOLID][solid] principles.
- Public classes and members should be documented.
- Favor explicit over implicit code.
- Favor consistency over any specific convention.
- Follow language-specific conventions ([C#][csCoding]).

Remember the adage:

> Always code as if the next developer who inherits your work
> is a violent sociopath who knows where you live!

## Naming Conventions

Naming is hard! But clear, consistent naming is crucial for code readability:

- Use descriptive, meaningful names that reveal intent
- Follow language-specific conventions ([C#][csIdentifier])
- Avoid abbreviations unless they're very well-known (e.g., `DB`, `AI`, etc.)
- Prefer verbose, clear names over short, cryptic ones
- But also, try to keep them relatively short
- Test names are generally an exception to these rules.
  Follow the conventions used by other tests in the project.

## Code Comments

Code comments can be very helpful to explain _why_
a chunk of code is doing what it's doing;
but if you're tempted to explain _what_ it's doing,
that's a good sign the code should be refactored.
Code should be self-documenting in that regard.

## Documentation

Documentation should be clear, concise, and up-to-date.
When adding or modifying features,
be sure to update any relevant documentation.
All documentation follows [Markdown][markdown] formatting rules.
Diagrams should use [PlantUML][plantUml] (for independent documents)
or [Mermaid][mermaid] (for in-line diagrams in Markdown).

## Error Handling

Proper error handling improves application robustness:

- Use exceptions for exceptional circumstances, not for control flow
- Log sufficient information to diagnose issues
- Provide helpful error messages
- Consider different error recovery strategies
- Don't swallow exceptions without good reason

## Security

Code should always be written with security in mind:

- Validate all input, especially user input
- Apply the principle of least privilege
- Keep dependencies up to date
- Use parameterized queries for database access
- Be cautious with serialization/deserialization
- Follow language-specific security guidelines
- Consider [OWASP][owasp] recommendations where applicable

## Performance

Performance should be a high priority during development:

- Focus on algorithmic efficiency first
- Be mindful of memory allocations
- Optimize critical paths
- Consider asynchronous operations where appropriate
- Batch database operations when possible
- Cache appropriately

## Testing

All code contributions should include appropriate tests.
Tests should be comprehensive and verify both expected behavior
and edge cases/error conditions.

In general, follow the principles of the [Test Pyramid][pyramid]:

- Unit tests for public functions, covering all possible code paths
  (This is where most of the work will be done.
  It's even possible to have more test code than production code here.)
- Some integration tests as necessary, covering a few happy or error paths,
  to make sure classes/components can communicate with each other successfully
- Perhaps some UI tests, if needed. These are the most brittle
  and are only for smoke testing.

Aim for 80%+ unit test coverage, especially for business-critical code.
But don't sacrifice test quality for coverage metrics.

## Commit Messages

This project uses [Conventional Commits][cc]
to standardize the format of commit messages.
This enables the automation of e.g. versioning
and the generation of changelogs & release notes.
See the [local documentation][ccDoc] for more information.

<!-- Source Code URIs -->

[ccDoc]: /docs/ConventionalCommits.md
[rulers]: /docs/VerticalRulers.md

<!-- Public URIs -->

[cc]: https://www.conventionalcommits.org
[csCoding]: https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions
[csIdentifier]: https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/identifier-names
[editorConfig]: https://editorconfig.org
[markdown]: https://www.markdownguide.org
[mermaid]: https://mermaid.js.org
[owasp]: https://owasp.org/www-project-top-ten
[plantUml]: https://plantuml.com
[pyramid]: https://martinfowler.com/articles/practical-test-pyramid.html
[solid]: https://en.wikipedia.org/wiki/SOLID
