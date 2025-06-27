# Vertical Rulers

Vertical rulers (or "guidelines") are visual markers in a code editor
that help developers keep their lines of code short.
This is especially important for activities like
side-by-side code comparisons,
as not all developers have lavish amounts of screen width.

## Recommended Ruler Positions

For this repository, the line width recommendations are:

- **80 characters** is the ideal maximum line width.
  Wrap lines of code by this point as often as possible.
- **100 characters** is fine, if it's more aesthetically pleasing
  than wrapping would be.
- **120 characters** _can be_ acceptable
  if the end of the line doesn't change often or is common boilerplate
  (such as cancellation tokens or other standard function parameters
  that don't change very often).
- **Over 120 characters** is not acceptable, and must be wrapped
  unless there's no other choice (e.g., a long URL link in a Markdown file).

For text files, wrap lines at commas, periods, or other natural phrasing breaks.
For code files, prefer stacking arguments and chained commands vertically.

Not all file types support wrapping lines in all cases.
When wrapping is not possible (for example, a long URI in a Markdown file),
don't worry about it. It's not the end of the world!
But where wrapping _is_ supported, keep within the rulers as best as possible.

To facilitate this, it's highly recommended
to configure the visual cues in your IDE of choice
as described below.

## How do I apply them?

The rules are already defined in the `.editorconfig` file.
If your IDE supports it (via a plugin or built-in functionality),
the vertical rulers should be displayed automatically.
Otherwise, you may need to manually set them up. For example:

- **Visual Studio:** install the [Editor Guidelines][guidelines] extension.
- **Visual Studio Code:** Go to `Settings`, search for `rulers`,
  click `Edit in settings.json`, and configure the following:
  ```json
  "editor.rulers": [
    {
      "column": 80,
      "color": "#00ff0050"
    },
    {
      "column": 100,
      "color": "#ffff0075"
    },
    {
      "column": 120,
      "color": "#8b0000ff"
    }
  ],
  ```

Happy coding!

<!-- Public URIs -->

[guidelines]: https://marketplace.visualstudio.com/items?itemName=PaulHarrington.EditorGuidelinesPreview
