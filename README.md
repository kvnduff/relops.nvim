# relops.nvim

Remote relative line operations for Neovim.

`relops.nvim` lets you act on lines away from the cursor without jumping to them first. It is useful when relative numbers show the target lines clearly and you want to delete, yank, change, or move those lines while keeping your cursor anchored.

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

### Local path development

```lua
-- lazy.nvim
{
  dir = "~/projects/relops/relops.nvim",
  name = "relops.nvim",
  opts = {},
}

-- packer.nvim
use {
  "/home/kevin/projects/relops/relops.nvim",
  config = function()
    require("relops").setup()
  end,
}
```

## Usage

The default mappings are:

| Mapping | Operation |
| --- | --- |
| `dr` | Delete a remote relative line range |
| `yr` | Yank a remote relative line range |
| `cr` | Change a remote relative line range |
| `mr` | Move a remote relative line range |

After the operation mapping, type a compact range expression using relative line counts and `j` or `k` directions.

### Delete, yank, and change

```text
dr15j18j  delete the range from 15 lines below through 18 lines below
yr5k10k   yank the range from 5 lines above through 10 lines above
cr5k8j    change the range from 5 lines above through 8 lines below
```

Single-line shorthand repeats the same target when both directions match:

```text
dr15jj    delete the line 15 lines below
yr15kk    yank the line 15 lines above
```

### Move

Move syntax includes a source range and a destination. The moved lines are inserted before the destination line.

```text
mr2j3j13j   move 2j..3j before the line 13j from the cursor
```

Move-to-here shorthand uses a final repeated direction instead of an explicit destination count:

```text
mr13kkk     move the line 13k to the current cursor line
mr5k8jj     move 5k..8j to the current cursor line
```

Moving into the selected source range is rejected and does not mutate the buffer.

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
  yank_highlight = {
    enabled = true,
    group = "IncSearch",
    duration = 180,
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
```

## Known tradeoffs

- Input after `dr`, `yr`, `cr`, or `mr` is read with `getcharstr()`, so native `showcmd` does not display the in-progress command.
- The command parser intentionally accepts only the compact relative-line grammar documented above.
- Clipboard writes to `+` and `*` are attempted when enabled, but ignored safely when those registers are unavailable.
- Undo and redo wrapping is optional because overriding `u` and `<C-r>` is invasive.

## License

MIT
