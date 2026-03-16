# marimo.nvim

`marimo.nvim` is a Neovim plugin for editing Marimo notebooks from inside Neovim and LazyVim.

V1 focuses on:

- detecting Marimo notebooks inside Python buffers
- starting a background `marimo edit` session
- rendering output previews in floating windows below `@app.cell` blocks
- entering a scrollable output panel for the current cell
- running the current cell or the whole notebook from Neovim

## Installation

Lazy.nvim / LazyVim:

```lua
{
  "sammy-spills/marimo.nvim",
  ft = "python",
  opts = {},
  keys = require("marimo").lazy_keys(),
}
```

## Default keymaps

- `<leader>me` start Marimo edit server
- `<leader>mw` start Marimo watch server
- `<leader>mc` run current cell
- `<leader>ma` run all cells
- `<leader>mr` restart kernel
- `<leader>mi` install dependencies
- `<leader>mo` enter output
- `<leader>mO` exit output
- `]m` jump to next cell
- `[m` jump to previous cell

## Commands

- `:MarimoStartEdit`
- `:MarimoStartWatch`
- `:MarimoRunCell`
- `:MarimoRunAll`
- `:MarimoRestartKernel`
- `:MarimoInstall <packages...>`
- `:MarimoEnable`
- `:MarimoDisable`
- `:MarimoEnterOutput`
- `:MarimoExitOutput`

## Notes

- Marimo notebooks stay as `python` filetype buffers. The plugin enables a buffer-local Marimo mode.
- Detection uses file heuristics first and then confirms with `uvx marimo check`.
- The Marimo server is started with `--headless` by default so Neovim stays the primary editing surface.
- Server startup prefers `uv run marimo ...` when the current buffer lives inside a `uv` project (`pyproject.toml` or `uv.lock`), and falls back to `uvx marimo ...` otherwise.
- Output previews render as non-focusable inline floats, with `<leader>mo` still opening a focused view for the current cell.
- Output rendering supports text, tracebacks, simple tables, and image/HTML placeholders in V1.
