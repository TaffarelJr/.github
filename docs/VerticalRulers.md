# Vertical Rulers

Vertical rulers (or "guidelines") are visual markers in a code editor
that help developers maintain appropriate line lengths.
This is especially important for activities like
side-by-side code comparisons,
as not all developers have wide displays.

## Recommended Ruler Positions

For this repo, the line width recommendations are:

- **80 characters** is the ideal maximum line width.
  Wrap lines of code by this point as often as possible.
- **100 characters** is OK once in a while, if it's more aesthetically pleasing
  than wrapping.
- **120 characters** _can be_ acceptable
  if the end of the line doesn't change often or is common boilerplate.
- **Over 120 characters** is not acceptable and must be wrapped
  unless there's no other choice.

For text files, wrap lines at commas, periods, or other natural phrasing breaks.
For code files, prefer stacking arguments and chained commands vertically.

Not all file types support wrapping lines in all cases.
When wrapping is not possible (for example, a long URI in a Markdown file),
this guideline may be relaxed.
Where wrapping _is_ supported, keep within the rulers as best as possible.

It's highly recommended to configure the visual cues in your IDE
as described below.

## How do I apply them?

Follow the instructions below for your IDE of choice.

### Visual Studio

Install the [Editor Guidelines][extension] extension.
The rulers are already defined in [.editorconfig][editorConfigFile].

### Visual Studio Code

The rulers are already defined in [settings.json][vsCodeSettingsFile].

### JetBrains Rider

1. Go to `File` → `Settings` (or `Rider` → `Preferences` on macOS)
2. Navigate to `Editor` → `Code Style`
3. Set `Hard wrap at` to `120`
4. Navigate to `Editor` → `General` → `Appearance`
5. Check `Show hard wrap and visual guides`
6. In `Visual guides`, enter: `80, 100, 120`

Rider also respects the `max_line_length` setting
in [.editorconfig][editorConfigFile].

### Sublime Text

1. Go to `Preferences` → `Settings`
2. Add the following to your user settings:

```json
"rulers": [80, 100, 120],
"draw_indent_guides": true,
```

### Vim / Neovim

For Vim or Neovim, add the following to your
[.vimrc][vimRC] or [init.vim][initVim]:

```vim
" Set color columns for vertical rulers
set colorcolumn=80,100,120

" Optional: Customize the color (this sets a subtle gray)
highlight ColorColumn ctermbg=236 guibg=#2c2d27
```

For more advanced configuration with different colors per column,
you can use a plugin like [vim-signature][vimSignature]
or configure with Lua in Neovim.

Happy coding!

<!-- Source Code URIs (alphabetical by file hierarchy) -->

[vsCodeSettingsFile]: ../.vscode/settings.json
[editorConfigFile]: ../.editorconfig

<!-- Public URIs (alphabetical by name) -->

[extension]: https://marketplace.visualstudio.com/items?itemName=PaulHarrington.EditorGuidelinesPreview
[initVim]: https://medium.com/@vimfinn/the-init-vim-file-38e218711620
[vimRC]: https://www.freecodecamp.org/news/vimrc-configuration-guide-customize-your-vim-editor
[vimSignature]: https://github.com/kshenoy/vim-signature
