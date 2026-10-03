# observatory.nvim

Repository health and compiler-grade symbol navigation inside Neovim, built on two CLIs:

- [`pulsar`](https://github.com/skastr0/pulsar) scores a repository and each change under one policy.
- [`quartz`](https://github.com/skastr0/quartz) answers questions about TypeScript types and symbols from the compiler.

Observatory tells you which code to read, why, and what is around it. It needs both CLIs on `PATH`
and Neovim 0.11 or newer. Pickers use [snacks.nvim](https://github.com/folke/snacks.nvim) when it is
loaded and fall back to the quickfix list.

## Install

```lua
{
  dir = "~/Projects/observatory.nvim",
  cmd = "Observatory",
  ft = { "typescript", "typescriptreact", "javascript", "javascriptreact", "rust" },
  opts = {},
}
```

## Commands

`:Observatory <command>`; with no command it opens the dashboard.

| Command | Source | What it shows |
|---|---|---|
| `dashboard` | pulsar | Readiness, category scores, weakest signals, files to read first |
| `files` | pulsar | Reading list: files ranked by how unhealthy their findings are |
| `findings [signal]` | pulsar | Every finding, worst signal first |
| `buffer` | pulsar | Findings for the current file |
| `signals` | pulsar | Each signal with its score; confirm to list its findings |
| `diff [base]` | pulsar | PASS / ROUTE / BLOCK for `base..WORKTREE`, plus what the change introduced |
| `score` | pulsar | Re-score now |
| `symbols` | quartz + pulsar | Exported symbols, marked unused / public / in a file with findings |
| `outline` | quartz + pulsar | Declarations in the current file with resolved types and findings |
| `usages [symbol]` | quartz | Every usage of the symbol under the cursor |
| `related [symbol]` | quartz | Types that use, or are used by, the type under the cursor |
| `type` | quartz | Resolved type at the cursor |
| `expand [symbol]` | quartz | Members of an exported type, fully resolved |

In a Snacks picker, `<c-q>` sends the list to quickfix.

Findings that carry a line also appear as ordinary diagnostics (source `pulsar`) and refresh after
each save. `require("observatory").status()` returns a statusline string with the readiness score.

## Options

```lua
{
  auto_score = true,      -- score a repository when one of its files is first opened
  score_on_save = true,   -- re-score in the background after saving
  filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact", "rust" },
  diagnostics = {
    enabled = true,
    file_level = false,   -- findings without a line stay out of the buffer
    virtual_text_min = vim.diagnostic.severity.WARN,
  },
  diff_base = "HEAD",
}
```

## Limits

- Quartz commands are TypeScript-only and start a fresh compiler per call (about a second on a mid-sized repo).
- `symbols`, `expand` and `related` see exported symbols only; `usages`, `outline` and `type` see everything.
- `usages` is implemented as a rename preview, because quartz has no find-references command.

## Test

```bash
OBSERVATORY_REPO=~/Projects/quartz OBSERVATORY_FILE=packages/engine/src/verification-operations.ts \
  nvim --headless -c "set rtp+=." -c "luafile tests/smoke.lua"
```
