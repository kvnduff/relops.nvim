local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd)
package.path = cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua;" .. package.path

local relops = require("relops")
local preview = require("relops.preview")
local original_notify = vim.notify
local notifications = {}

vim.notify = function(message, level, opts)
  table.insert(notifications, { message = tostring(message), level = level, opts = opts })
end

local tests = {}

local function test(name, fn)
  table.insert(tests, { name = name, fn = fn })
end

local function lines(count)
  local result = {}

  for i = 1, count do
    result[i] = "L" .. i
  end

  return result
end

local function range_lines(first, last)
  local result = {}

  for i = first, last do
    table.insert(result, "L" .. i)
  end

  return result
end

local function concat(...)
  local result = {}

  for _, list in ipairs({ ... }) do
    for _, item in ipairs(list) do
      table.insert(result, item)
    end
  end

  return result
end

local function without_range(count, first, last)
  local result = {}

  for i = 1, count do
    if i < first or i > last then
      table.insert(result, "L" .. i)
    end
  end

  return result
end

local function buffer_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function eq(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error((label or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual:   " .. vim.inspect(actual), 2)
  end
end

local function ok(value, label)
  if not value then
    error(label or "expected truthy value", 2)
  end
end

local function base_setup(overrides)
  local opts = vim.tbl_deep_extend("force", {
    notifications = false,
    yank_highlight = { enabled = false },
    clipboard = {
      unnamed = true,
      yank_register = true,
      delete_register = true,
      system = false,
      selection = false,
    },
    undo = { wrap = false },
  }, overrides or {})

  relops.setup(opts)
end

local function reset(count, cursor, opts)
  vim.cmd("silent! %bwipeout!")
  vim.cmd("enew!")
  vim.bo.swapfile = false
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines(count))
  vim.api.nvim_win_set_cursor(0, cursor or { 1, 0 })
  vim.fn.setreg('"', "")
  vim.fn.setreg("0", "")
  vim.fn.setreg("1", "")
  notifications = {}
  base_setup(opts)
end

local function feed(keys)
  local term = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.fn.feedkeys(term, "xt")
end

local function register_lines(reg)
  return vim.fn.getreg(reg, 1, true)
end

local function has_notification(fragment)
  for _, item in ipairs(notifications) do
    if item.message:find(fragment, 1, true) then
      return true
    end
  end

  return false
end

local function floating_wins()
  local found = {}

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      table.insert(found, win)
    end
  end

  return found
end

local function preview_gutter(win, lnum)
  return vim.api.nvim_eval_statusline(vim.wo[win].statuscolumn, {
    winid = win,
    use_statuscol_lnum = lnum,
  }).str
end

local function preview_gutters(win)
  local gutters = {}

  for lnum = 1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) do
    gutters[lnum] = preview_gutter(win, lnum)
  end

  return gutters
end

test("delete parses a single remote line and sets delete registers", function()
  reset(20, { 10, 0 })

  feed("dr2j")

  eq(buffer_lines(), without_range(20, 12, 12), "delete should remove line 12")
  eq(vim.api.nvim_win_get_cursor(0), { 10, 0 }, "delete should keep cursor anchored")
  eq(register_lines('"'), { "L12" }, "unnamed register should receive deleted line")
  eq(register_lines("1"), { "L12" }, "delete register should receive deleted line")
end)

test("delete parses a remote range and sets delete registers", function()
  reset(20, { 10, 0 })

  feed("drr2j4j")

  eq(buffer_lines(), without_range(20, 12, 14), "delete should remove 12..14")
  eq(vim.api.nvim_win_get_cursor(0), { 10, 0 }, "delete should keep cursor anchored")
  eq(register_lines('"'), { "L12", "L13", "L14" }, "unnamed register should receive deleted lines")
  eq(register_lines("1"), { "L12", "L13", "L14" }, "delete register should receive deleted lines")
end)

test("yank supports mixed above and below ranges", function()
  reset(20, { 10, 0 })

  feed("yrr2k3j")

  eq(buffer_lines(), lines(20), "yank should not mutate buffer")
  eq(register_lines('"'), { "L8", "L9", "L10", "L11", "L12", "L13" }, "unnamed register should receive yanked lines")
  eq(register_lines("0"), { "L8", "L9", "L10", "L11", "L12", "L13" }, "yank register should receive yanked lines")
end)

test("range current-line token can be the second endpoint", function()
  reset(20, { 10, 0 })

  feed("yrr2k0")

  eq(buffer_lines(), lines(20), "yank to current line should not mutate buffer")
  eq(register_lines('"'), { "L8", "L9", "L10" }, "default current-line token should target the cursor line")
  eq(register_lines("0"), { "L8", "L9", "L10" }, "yank register should receive range through cursor")
end)

test("range current-line token is configurable", function()
  reset(20, { 10, 0 }, { syntax = { current_line = "." } })

  feed("yrr2k.")

  eq(register_lines('"'), { "L8", "L9", "L10" }, "custom current-line token should target the cursor line")
  eq(register_lines("0"), { "L8", "L9", "L10" }, "yank register should receive custom-token range")
end)

test("range parser does not treat zero inside a larger count as current line", function()
  reset(20, { 10, 0 })

  feed("yrr2k10j")

  eq(register_lines('"'), range_lines(8, 20), "10j should remain a normal remote relative target")
  eq(register_lines("0"), range_lines(8, 20), "yank register should receive the full multi-digit range")
end)

test("single remote line syntax yanks one line", function()
  reset(20, { 10, 0 })

  feed("yr3k")

  eq(register_lines('"'), { "L7" }, "single-line syntax should target one line")
  eq(register_lines("0"), { "L7" }, "yank register should receive one line")
end)

test("change replaces a single remote line with insert text", function()
  reset(10, { 1, 0 })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "",
    "text2",
    "text3",
    "",
    "",
    "text6",
    "text7",
    "text8",
    "",
    "",
  })

  feed("cr4jhello<Esc>")

  eq(buffer_lines(), {
    "",
    "text2",
    "text3",
    "",
    "hello",
    "text6",
    "text7",
    "text8",
    "",
    "",
  }, "change should replace the target line without consuming the following line")
  eq(vim.api.nvim_win_get_cursor(0), { 1, 0 }, "change should restore the original cursor after InsertLeave")
  eq(vim.api.nvim_get_mode().mode, "n", "change should finish in normal mode after escape")
end)

test("change replaces a remote range with insert text", function()
  reset(10, { 1, 0 })

  feed("crr4j6jhello<Esc>")

  eq(
    buffer_lines(),
    concat(range_lines(1, 4), { "hello" }, range_lines(8, 10)),
    "change should replace the selected range with one inserted line"
  )
  eq(vim.api.nvim_win_get_cursor(0), { 1, 0 }, "change should restore the original cursor after InsertLeave")
  eq(register_lines("1"), { "L5", "L6", "L7" }, "change should set delete-like register")
end)

test("change range accepts multiline insert replacement", function()
  reset(10, { 1, 0 })

  feed("crr4j6jalpha<CR>beta<Esc>")

  eq(
    buffer_lines(),
    concat(range_lines(1, 4), { "alpha", "beta" }, range_lines(8, 10)),
    "change should let insert mode decide replacement line count"
  )
  eq(vim.api.nvim_win_get_cursor(0), { 1, 0 }, "change should restore the original cursor after InsertLeave")
end)

test("change single-line replacement is one native undo step", function()
  reset(10, { 1, 0 })

  feed("cr5jhello<Esc>")
  eq(
    buffer_lines(),
    concat(range_lines(1, 5), { "hello" }, range_lines(7, 10)),
    "change should replace the remote line before undo"
  )

  feed("u")

  eq(buffer_lines(), lines(10), "one undo should restore the original remote line")
end)

test("change range replacement is one native undo step", function()
  reset(10, { 1, 0 })

  feed("crr4j6jhello<Esc>")
  eq(
    buffer_lines(),
    concat(range_lines(1, 4), { "hello" }, range_lines(8, 10)),
    "change should replace the remote range before undo"
  )

  feed("u")

  eq(buffer_lines(), lines(10), "one undo should restore the original remote range")
end)

test("single move relocates a line to the adjusted destination anchor", function()
  reset(15, { 10, 0 })

  feed("mr2j5j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 11), range_lines(13, 14), { "L12", "L15" }),
    "single move should remove source and insert before the shifted destination"
  )
  eq(register_lines("1"), { "L12" }, "move should set delete-like register")
end)

test("single move preserves destination content while keeping line count stable", function()
  reset(7, { 1, 0 })

  vim.api.nvim_buf_set_lines(0, 3, 4, false, { "L4 text" })

  feed("mr3j6j")

  eq(
    buffer_lines(),
    { "L1", "L2", "L3", "L5", "L6", "L4 text", "L7" },
    "single move should close the source gap and insert before the shifted destination"
  )
end)

test("range move relocates lines to the adjusted destination anchor", function()
  reset(30, { 10, 0 })

  feed("mrr2j3j13j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 11), range_lines(14, 22), range_lines(12, 13), range_lines(23, 30)),
    "range move should remove source and insert before the shifted destination"
  )
  eq(register_lines("1"), { "L12", "L13" }, "range move should set delete-like register")
end)

test("default move dispatcher preserves normal mark setting for other mark names", function()
  reset(10, { 4, 0 })

  feed("ma")

  local pos = vim.fn.getpos("'a")
  eq({ pos[2], pos[3] - 1 }, { 4, 0 }, "ma should still set mark a at the cursor")
  eq(buffer_lines(), lines(10), "setting a mark should not mutate the buffer")
end)

test("default mappings avoid timeout-sensitive normal-mode prefixes", function()
  reset(10, { 4, 0 })

  eq(vim.fn.maparg("dr", "n"), "", "delete should not depend on a normal-mode dr mapping")
  eq(vim.fn.maparg("yr", "n"), "", "yank should not depend on a normal-mode yr mapping")
  eq(vim.fn.maparg("cr", "n"), "", "change should not depend on a normal-mode cr mapping")
  ok(vim.fn.maparg("r", "o") ~= "", "operator-pending r should enter relops for d/y/c")

  local move_map = vim.fn.maparg("m", "n", false, true)
  ok(type(move_map) == "table" and move_map.lhs == "m", "move should install an m dispatcher")
  ok(move_map.nowait == 1 or move_map.nowait == true, "m dispatcher should not wait for mr")
end)

test("range move to the line after the source is a no-op relocation", function()
  reset(20, { 10, 0 })

  feed("mrr2j5j6j")

  eq(buffer_lines(), lines(20), "destination immediately after source should preserve line order")
end)

test("range move preserves destination content below the source", function()
  reset(7, { 1, 0 })

  feed("mrr3j4j6j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 3), { "L6", "L4", "L5", "L7" }),
    "range move should keep the original destination content after the moved block"
  )
end)

test("range move rejects destinations inside the source range", function()
  reset(15, { 5, 0 }, { notifications = true })

  feed("mrr2j4j3j")

  eq(buffer_lines(), lines(15), "move into source range should not mutate")
  ok(has_notification("Move destination cannot be inside the source range"), "overlap should notify")
end)

test("move-to-current moves a single remote line to the cursor", function()
  reset(15, { 10, 0 })

  feed("mr3j0")

  eq(
    buffer_lines(),
    concat(range_lines(1, 9), { "L13" }, range_lines(10, 12), range_lines(14, 15)),
    "move-to-current should insert before the cursor line"
  )
end)

test("move accepts current-line token as a destination coordinate", function()
  reset(15, { 10, 0 })

  feed("mr3k0")

  eq(
    buffer_lines(),
    concat(range_lines(1, 6), range_lines(8, 9), { "L7" }, range_lines(10, 15)),
    "current-line destination token should land at the shifted cursor coordinate"
  )
end)

test("move accepts current-line token as the second source endpoint", function()
  reset(15, { 10, 0 })

  feed("mrr3k02j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 6), { "L11" }, range_lines(7, 10), range_lines(12, 15)),
    "source range should support distant target through the cursor line"
  )
end)

test("move accepts source range through current line with a remote destination", function()
  reset(20, { 10, 0 })

  feed("mrr5j09k")

  eq(
    buffer_lines(),
    concat(range_lines(10, 15), range_lines(1, 9), range_lines(16, 20)),
    "source range should support below target through the cursor line"
  )
end)

test("out-of-buffer ranges do not mutate buffers", function()
  reset(10, { 5, 0 }, { notifications = true })

  feed("drr99j100j")

  eq(buffer_lines(), lines(10), "out-of-buffer delete should not mutate")
  ok(has_notification("Range is outside the buffer"), "out-of-buffer range should notify")
end)

test("invalid input and escape aborts do not mutate buffers", function()
  reset(10, { 5, 0 }, { notifications = true })

  feed("drx")

  eq(buffer_lines(), lines(10), "invalid command should not mutate")
  ok(has_notification("Invalid range"), "invalid command should notify")

  reset(10, { 5, 0 }, { notifications = true })
  feed("dr<Esc>")

  eq(buffer_lines(), lines(10), "escape should abort without mutating")
  eq(#notifications, 0, "escape abort should be clean")

  reset(10, { 5, 0 }, { notifications = true })
  feed("dr<C-c>")

  eq(buffer_lines(), lines(10), "ctrl-c should abort without mutating")
  eq(#notifications, 0, "ctrl-c abort should be clean")
end)

test("undo and redo wrappers restore buffer and cursor when enabled", function()
  reset(20, { 10, 0 }, { undo = { wrap = true } })

  feed("drr2j4j")
  eq(buffer_lines(), without_range(20, 12, 14), "delete should mutate before undo")

  feed("u")
  eq(buffer_lines(), lines(20), "undo should restore buffer")
  eq(vim.api.nvim_win_get_cursor(0), { 10, 0 }, "undo wrapper should restore cursor")

  feed("<C-r>")
  eq(buffer_lines(), without_range(20, 12, 14), "redo should reapply delete")
  eq(vim.api.nvim_win_get_cursor(0), { 10, 0 }, "redo wrapper should restore cursor")
end)

test("undo and redo wrappers restore move operations when enabled", function()
  reset(15, { 10, 0 }, { undo = { wrap = true } })

  feed("mr3j0")
  eq(
    buffer_lines(),
    concat(range_lines(1, 9), { "L13" }, range_lines(10, 12), range_lines(14, 15)),
    "move should mutate before undo"
  )

  feed("u")
  eq(buffer_lines(), lines(15), "undo should restore moved lines")
  eq(vim.api.nvim_win_get_cursor(0), { 10, 0 }, "undo wrapper should restore cursor after move")

  feed("<C-r>")
  eq(
    buffer_lines(),
    concat(range_lines(1, 9), { "L13" }, range_lines(10, 12), range_lines(14, 15)),
    "redo should reapply move"
  )
  eq(vim.api.nvim_win_get_cursor(0), { 10, 0 }, "redo wrapper should restore cursor after move")
end)

test("repeated setup removes old relops mappings", function()
  reset(5, { 3, 0 })

  ok(vim.fn.maparg("r", "o") ~= "", "default operator-pending mapping should exist")
  ok(vim.fn.maparg("m", "n") ~= "", "default move dispatcher should exist")

  relops.setup({
    notifications = false,
    yank_highlight = { enabled = false },
    mappings = { enabled = true, delete = "zx", yank = false, change = false, move = false },
  })
  ok(vim.fn.maparg("zx", "n") ~= "", "custom mapping should exist")
  eq(vim.fn.maparg("m", "n"), "", "default move dispatcher should be removed for custom setup")

  relops.setup({ mappings = { enabled = false }, notifications = false })
  eq(vim.fn.maparg("zx", "n"), "", "custom mapping should be removed on disabled setup")
  eq(vim.fn.maparg("r", "o"), "", "operator-pending mapping should be removed on disabled setup")
end)

test("setup validates obvious bad config types", function()
  local success, err = pcall(function()
    relops.setup({ undo = { wrap = "yes" } })
  end)

  ok(not success, "bad setup type should fail")
  ok(tostring(err):find("undo.wrap", 1, true), "validation error should name the bad key")

  success, err = pcall(function()
    relops.setup({ syntax = { current_line = "j" } })
  end)

  ok(not success, "bad current-line token should fail")
  ok(tostring(err):find("syntax.current_line", 1, true), "validation error should name the bad token")
end)

test("preview config defaults to disabled", function()
  reset(5, { 3, 0 })

  eq(relops.defaults.preview.enabled, false, "preview should default to disabled")
  eq(relops.defaults.preview.max_height, 7, "preview should default to a bounded height")
end)

test("setup validates preview config types", function()
  local success, err = pcall(function()
    relops.setup({ preview = { enabled = "yes" } })
  end)

  ok(not success, "bad preview type should fail")
  ok(tostring(err):find("preview.enabled", 1, true), "validation error should name the bad key")

  success, err = pcall(function()
    relops.setup({ preview = { max_height = "tall" } })
  end)

  ok(not success, "bad preview height should fail")
  ok(tostring(err):find("preview.max_height", 1, true), "validation error should name the bad key")
end)

test("preview state tracks the pending count for range grammar", function()
  reset(20, { 10, 0 })

  local token = relops.defaults.syntax.current_line

  local state = preview._state("yank", "3")
  eq(state.stage, "target", "a bare count targets a single line")
  eq(state.pending, 3, "pending count should be parsed")

  state = preview._state("yank", "r2j5")
  eq(state.stage, "range_end", "second endpoint should be the pending stage")
  eq(state.pending, 5, "pending count should be the second endpoint")
  eq(state.locked, { n1 = 2, dir1 = "j" }, "first endpoint should be locked")
  ok(not state.hint:find(token, 1, true), "a pending count should drop the current-line token")

  state = preview._state("yank", "r2j15")
  eq(state.pending, 15, "a multi-digit pending count should be read whole")
  eq(state.locked, { n1 = 2, dir1 = "j" }, "a multi-digit count should keep the locked endpoint")

  state = preview._state("yank", "r2j")
  eq(state.pending, nil, "a resolved endpoint leaves nothing pending")
  ok(state.hint:find("0", 1, true), "range end hint should offer the current-line token")
end)

test("preview state tracks the pending count for move grammar", function()
  reset(20, { 10, 0 })

  local state = preview._state("move", "r2j5j9")
  eq(state.stage, "move_dest", "third count should be the destination")
  eq(state.pending, 9, "pending count should be the destination")
  eq(state.locked, { n1 = 2, dir1 = "j", n2 = 5, dir2 = "j" }, "source range should be locked")

  state = preview._state("move", "3j4")
  eq(
    state.locked,
    { n1 = 3, dir1 = "j", n2 = 3, dir2 = "j" },
    "a single source locks both endpoints"
  )

  state = preview._state("move", "r2j05")
  eq(
    state.locked,
    { n1 = 2, dir1 = "j", n2 = 0, dir2 = "j" },
    "a source ending here locks the current line"
  )

  eq(preview._state("move", "3j4j"), nil, "a complete command has no preview state")
end)

test("preview model resolves both directions for a single target", function()
  reset(20, { 10, 0 })

  local model = preview._model(0, 10, "yank", "3")
  eq(model.expr, "yr3", "expression should include the operation mapping")
  eq(#model.rows, 2, "a single target previews one row per direction")
  eq(model.rows[1], { dir = "k", offset = "3k", lnum = 7, text = "L7" }, "k row comes first")
  eq(model.rows[2], { dir = "j", offset = "3j", lnum = 13, text = "L13" }, "j row comes second")
end)

test("preview model excerpts a pending range endpoint", function()
  reset(20, { 10, 0 })

  local model = preview._model(0, 10, "yank", "r2j5")
  eq(#model.rows, 6, "each direction contributes first, elision, last")
  eq(model.rows[4], { dir = "j", offset = "2j", lnum = 12, text = "L12" }, "j range starts at 12")
  eq(model.rows[5], { dir = "j", virt = "… 2 more" }, "hidden lines should be counted")
  eq(model.rows[6], { dir = "j", offset = "5j", lnum = 15, text = "L15" }, "j range ends at 15")
  eq(
    model.rows[1],
    { dir = "k", offset = "5k", lnum = 5, text = "L5" },
    "a group straddling the cursor should start at its topmost line"
  )
  eq(
    model.rows[3],
    { dir = "k", offset = "2j", lnum = 12, text = "L12" },
    "a group straddling the cursor should end at its bottommost line"
  )

  model = preview._model(0, 10, "yank", "r2j3")
  eq(#model.rows, 5, "an excerpt that hides nothing drops the elision row")
  eq(model.rows[4], { dir = "j", offset = "2j", lnum = 12, text = "L12" }, "j excerpt starts at 12")
  eq(model.rows[5], { dir = "j", offset = "3j", lnum = 13, text = "L13" }, "j excerpt ends at 13")
end)

test("preview model marks candidates outside the buffer", function()
  reset(20, { 3, 0 })

  local model = preview._model(0, 3, "yank", "10")
  eq(model.rows[1].dim, true, "k candidate above the buffer should be dimmed")
  eq(model.rows[1].virt, "past start of buffer (line 1)", "dimmed row should name the edge")
  eq(model.rows[2], { dir = "j", offset = "10j", lnum = 13, text = "L13" }, "j row is unaffected")

  model = preview._model(0, 3, "yank", "99")
  eq(model.rows[2].dim, true, "j candidate below the buffer should be dimmed")
  eq(model.rows[2].virt, "past end of buffer (line 20)", "dimmed row should name the last line")
end)

test("preview model shows the landing seam for a move destination", function()
  reset(20, { 10, 0 })

  local model = preview._model(0, 10, "move", "r2j5j9")
  eq(
    model.rows[3],
    { dir = "j", offset = "9j", seam = "above", lnum = 14, text = "L18" },
    "j seam should sit above the landed block in post-move coordinates"
  )
  eq(
    model.rows[4],
    { dir = "j", offset = "9j", seam = "below", lnum = 19, text = "L19" },
    "j seam should continue below the landed block"
  )
  eq(model.rows[1].virt, "(start of buffer)", "k destination lands at the top of the buffer")
end)

test("preview model dims a move destination inside the source range", function()
  reset(20, { 10, 0 })

  local model = preview._model(0, 10, "move", "r2j5j3")
  eq(#model.rows, 3, "the usable k destination still previews its seam")
  eq(
    model.rows[3],
    { dir = "j", offset = "3j", dim = true, virt = "(inside the source range)" },
    "a destination inside the source range should be dimmed"
  )
end)

test("preview model previews the locked target between counts", function()
  reset(20, { 10, 0 })

  local model = preview._model(0, 10, "yank", "r2j")
  eq(
    model.rows,
    { { dir = "j", offset = "2j", lnum = 12, text = "L12" } },
    "a locked endpoint should stay previewed while no count is pending"
  )

  model = preview._model(0, 10, "yank", "")
  eq(model.rows, {}, "nothing is locked yet before the first count")

  eq(preview._model(0, 10, "yank", "r2j5j"), nil, "a complete command has no preview model")
end)

test("preview window opens and closes", function()
  reset(20, { 10, 0 }, { preview = { enabled = true } })

  local model = preview._model(0, 10, "yank", "3")
  preview._show(model, 0)
  eq(#floating_wins(), 1, "showing a model should open one float")

  preview.close()
  eq(#floating_wins(), 0, "closing should leave no float behind")
end)

test("preview window reuses one float across renders", function()
  reset(20, { 10, 0 }, { preview = { enabled = true } })

  local rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }

  preview._show(preview._model(0, 10, "yank", "3"), 0)

  local win = floating_wins()[1]

  eq(vim.api.nvim_win_get_height(win), 3, "one row per direction should fit three lines")

  preview._show(preview._model(0, 10, "yank", "r2j5"), 0)

  eq(floating_wins(), { win }, "a later render should reuse the same float")
  eq(vim.api.nvim_win_get_height(win), 7, "reconfiguring should resize to the new rows")
  eq(vim.api.nvim_win_get_config(win).border, rounded, "reconfiguring should keep the border")
  eq(
    vim.api.nvim_win_get_config(win).title,
    { { " relops.nvim ", "Title" }, { "· <count>j / <count>k ", "Comment" } },
    "the border title should name the plugin and carry the hint"
  )
  ok(
    vim.api.nvim_win_get_position(win)[1] <= vim.o.lines - vim.o.cmdheight - 1,
    "the float should stop above the statusline row"
  )
  ok(vim.wo[win].statuscolumn ~= "", "reconfiguring should keep the gutter expression")
  eq(preview_gutter(win, 1), "k 5k  5 │ ", "the gutter should right-align every column")
  eq(preview_gutter(win, 2), "k       │ ", "an elision row should hold the column widths open")
  eq(
    preview_gutter(win, 4),
    "   yank ┈ ",
    "the expression row should label the operation and sit between the two directions"
  )
  eq(
    #preview_gutter(win, 4),
    #preview_gutter(win, 1),
    "the expression divider should align with the row separator"
  )
  eq(preview_gutter(win, 5), "j 2j 12 │ ", "the j candidate should render below the expression")

  preview.close()
end)

test("preview gutter keeps columns aligned when line numbers widen", function()
  reset(200, { 100, 0 }, { preview = { enabled = true } })

  preview._show(preview._model(0, 100, "yank", "5"), 0)

  local win = floating_wins()[1]

  eq(preview_gutter(win, 1), "k 5k  95 │ ", "a shorter line number should pad to the widest row")
  eq(preview_gutter(win, 3), "j 5j 105 │ ", "the widest line number should set the column width")
  eq(#preview_gutter(win, 3), #preview_gutter(win, 1), "every row should render one width")

  preview.close()
end)

test("preview leaves no window behind after a completed operation", function()
  reset(20, { 10, 0 }, { preview = { enabled = true } })

  local buffers = #vim.api.nvim_list_bufs()

  feed("yr3j")

  eq(register_lines("0"), { "L13" }, "yank should still take the remote line")
  eq(#vim.api.nvim_list_bufs(), buffers + 1, "preview should build its scratch buffer")
  eq(#floating_wins(), 0, "preview should close when the command completes")
end)

test("preview follows the pending command through the read loop", function()
  reset(20, { 10, 0 }, { preview = { enabled = true } })

  local script = { "r", "2", "j", "5", "j" }
  local index = 0
  local seen = {}
  local original = vim.fn.getcharstr

  vim.fn.getcharstr = function()
    index = index + 1

    if index > 1 then
      local win = floating_wins()[1]

      if win then
        seen[#seen + 1] = preview_gutters(win)
      end
    end

    return script[index] or "\027"
  end

  local success, err = pcall(function()
    feed("yr")
    eq(#seen, 4, "every accepted keystroke should redraw the preview")
    eq(seen[1], { "yank ┈ " }, "the bare expression should preview no rows")
    eq(
      seen[3],
      { "   yank ┈ ", "j 2j 12 │ " },
      "a locked endpoint should stay previewed between counts"
    )
    eq(seen[4][1], "k 5k  5 │ ", "a pending endpoint should preview the k direction first")
    eq(seen[4][4], "   yank ┈ ", "the expression should split the two directions")
    eq(seen[4][5], "j 2j 12 │ ", "the j direction should preview below the expression")
  end)

  vim.fn.getcharstr = original

  eq(register_lines("0"), range_lines(12, 15), "the operation should still complete")

  if not success then
    error(err, 0)
  end
end)

test("preview stays inert when disabled", function()
  reset(20, { 10, 0 })

  local buffers = #vim.api.nvim_list_bufs()

  feed("yrr2j5j")

  eq(register_lines("0"), range_lines(12, 15), "range yank should be unchanged")
  eq(#vim.api.nvim_list_bufs(), buffers, "disabled preview should build nothing")
  eq(#floating_wins(), 0, "disabled preview should never open a window")
end)

test("preview closes when a pending command is aborted", function()
  reset(20, { 10, 0 }, { preview = { enabled = true } })

  feed("dr<Esc>")

  eq(buffer_lines(), lines(20), "escape should abort without mutating")
  eq(#floating_wins(), 0, "escape should close the preview")

  feed("dr<C-c>")

  eq(buffer_lines(), lines(20), "ctrl-c should abort without mutating")
  eq(#floating_wins(), 0, "ctrl-c should close the preview")
end)

test("preview closes when the pending command raises", function()
  reset(20, { 10, 0 }, { preview = { enabled = true } })

  local original = vim.fn.getcharstr

  vim.fn.getcharstr = function()
    error("Keyboard interrupt", 0)
  end

  local success, err = pcall(function()
    ok(not pcall(feed, "yr"), "a raised interrupt should propagate out of the wrapper")
    eq(#floating_wins(), 0, "a raised interrupt should close the preview")
  end)

  vim.fn.getcharstr = original

  if not success then
    error(err, 0)
  end
end)

test("module exposes the v0.3.0 release version", function()
  eq(relops.version, "0.3.0", "module version should match the release")
end)

local failures = {}

for _, item in ipairs(tests) do
  local success, err = pcall(item.fn)

  if success then
    print("ok - " .. item.name)
  else
    table.insert(failures, { name = item.name, err = err })
    print("not ok - " .. item.name)
    print(err)
  end
end

vim.notify = original_notify

if #failures > 0 then
  print(string.format("%d/%d relops tests failed", #failures, #tests))
  vim.cmd("cquit")
end

print(string.format("%d relops tests passed", #tests))
vim.cmd("qa!")
