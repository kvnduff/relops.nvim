# relops.nvim

Remote relative line operations for Neovim.

Current release: `v0.3.0`.

`relops.nvim` lets you act on lines away from the cursor without jumping to them first.
It is useful when relative numbers show the target lines clearly and you want to delete, yank,
change, or move those lines while keeping your cursor anchored.

## Requirements

- Neovim 0.9+

## Installation

### lazy.nvim

```lua
{
  "kvnduff/relops.nvim",
  opts = {},
}
```

### packer.nvim

```lua
use {
  "kvnduff/relops.nvim",
  config = function()
    require("relops").setup()
  end,
}
```

### vim-plug

```vim
Plug 'kvnduff/relops.nvim'
```

Then configure it from Lua:

```lua
require("relops").setup()
```

## Usage

The default mappings are:

| Mapping | Operation |
| --- | --- |
| `dr` | Delete a remote relative line or range |
| `yr` | Yank a remote relative line or range |
| `cr` | Change a remote relative line or range |
| `mr` | Move a remote relative line or range |

The default mappings avoid Neovim's normal mapping timeout: `dr`, `yr`, and `cr`
enter relops through an operator-pending `r`, and `mr` uses an immediate `m`
dispatcher that forwards non-`r` keys to native mark setting.

After the operation mapping, type a compact expression using relative line counts and `j` or `k` directions.

In v0.3.0, the syntax changed to make the command intent clearer:

```text
r   remote line
rr  remote range
```

For the default mappings, `dr5j` deletes one remote line and `drr2j5j` deletes a remote range.
Pre-v0.3 repeated-direction forms such as `dr15jj`, `yr15kk`, `mr13kk0`, and
`mr2j3j13j` are no longer the documented command syntax.
Update macros, notes, and muscle memory to the v0.3.0 forms.

Use `0` for the current cursor line when the current line is the second endpoint of a range,
a move destination, or the second source endpoint of a range move.

### Delete, yank, and change

```text
dr15j     delete the single remote line 15 below
yr5k      yank the single remote line 5 above
cr8j      change the single remote line 8 below
```

Repeat the `r` for a remote range:

```text
drr15j18j  delete the range from 15 lines below through 18 lines below
yrr5k10k   yank the range from 5 lines above through 10 lines above
yrr5k0     yank the range from 5 lines above through the current line
crr5k8j    change the range from 5 lines above through 8 lines below
```

Change is linewise: the target line or range is replaced by one empty insert
line. Type one line to replace the whole range with one line, or press Return in
insert mode to create multiple replacement lines. The linewise replacement and
inserted text undo as one change.

Because range order does not matter, put the remote endpoint first when using the current line
as the other endpoint.
Do not add `j` or `k` after `0`.

### Move

Move syntax includes a source and a destination.
Move relocates whole lines: it captures the source lines, deletes them so the gap closes,
then inserts them before the destination anchor. The destination is evaluated against the
original visible buffer; when the destination is below the source, it shifts upward after
the source is removed. The buffer line count stays stable, destination contents are preserved,
and destinations inside the source range are rejected. Registers receive the original moved contents.

```text
mr5j9j      move the single remote line 5 below to the line 9 below
mr5j0       move the single remote line 5 below to the current cursor line
```

Repeat the `r` for a remote source range:

```text
mrr2j5j9j   move 2j..5j so the range starts at the line 9j from the cursor
mrr2j5j0    move 2j..5j to the current cursor line
mrr5j09k    move 5j..current line so the range starts at the line 9k from the cursor
```

For example, `mrr3j4j9j` moves `3j..4j` to the original `9j` anchor. After the source
is removed, original `9j` shifts up by two lines, and the moved text is inserted before
that shifted anchor.

## Configuration

Default configuration:

```lua
require("relops").setup({
  mappings = {
    enabled = true,
    delete = "dr",
    yank = "yr",
    change = "cr",
    move = "mr",
  },
  syntax = {
    current_line = "0",
  },
  yank_highlight = {
    enabled = true,
    group = "IncSearch",
    duration = 180,
  },
  preview = {
    enabled = false,
    border = "rounded",
    max_height = 7,
    label_group = "Title",
    number_group = "LineNr",
    hint_group = "Comment",
    expression_group = "CursorLine",
  },
  clipboard = {
    unnamed = true,
    yank_register = true,
    delete_register = true,
    system = true,
    selection = true,
  },
  undo = {
    wrap = false,
  },
  notifications = true,
})
```

### Current-line token

The default current-line token is `0`. It can be changed to another single non-conflicting character:

```lua
require("relops").setup({
  syntax = {
    current_line = ".",
  },
})
```

### Command preview

By default, `relops.nvim` does not show a preview while a command is pending. Enable it to see the
lines each direction key would act on:

```lua
require("relops").setup({
  preview = {
    enabled = true,
  },
})
```

The preview opens above the statusline as soon as relops takes over input and closes when the
command completes or is cancelled. Its border title names the plugin and what the syntax accepts
next. The keys typed so far sit on their own shaded line, ruled off with a dotted divider and named
with the operation on the left; that line stands in for the cursor, so `k` candidates render above
it and `j` candidates below. Each candidate carries its relative offset, absolute line number, and
content, highlighted with the source buffer's syntax. A range shows its first line, a count of the
lines between, and its last line. A move destination shows the lines that would end up directly
above and below the moved block. A candidate outside the buffer is dimmed and names the edge it ran
past. A move destination inside the source range is dimmed the same way.

The window is at most `max_height` lines tall. The default 7 is the height of the tallest preview,
so a smaller value clips the bottom rows of the preview. A value below 1 is raised to 1, the height
of the expression line.

### Undo and redo wrapping

By default, `relops.nvim` does not map `u` or `<C-r>`. That keeps the plugin non-invasive for public use.

If you want undo and redo to restore the cursor/view position around remote operations, opt in:

```lua
require("relops").setup({
  undo = {
    wrap = true,
  },
})
```

## API

```lua
local relops = require("relops")

relops.setup(opts)
relops.delete()
relops.yank()
relops.change()
relops.move()
relops.undo()
relops.redo()
relops.version
```

## Known tradeoffs

- Input after `dr`, `yr`, `cr`, or `mr` is read with `getcharstr()`, so native `showcmd`
  does not display the in-progress command. Enable `preview` to see the pending command instead.
- The preview window does not wrap, so a line wider than the window is truncated without a marker.
- The preview hint renders in the window's border title, so `preview.border = "none"` hides it.
- The default `mr` timeout fix maps `m` and preserves native marks for non-`r` mark names.
  If you rely on other normal-mode mappings that start with `m`, remap `move` to a less
  conflicting key sequence.
- The command parser intentionally accepts only the compact relative-line grammar documented above.
- Clipboard writes to `+` and `*` are attempted when enabled, but ignored safely when those registers are unavailable.
- Undo and redo wrapping is optional because overriding `u` and `<C-r>` is invasive.

## License

MIT
