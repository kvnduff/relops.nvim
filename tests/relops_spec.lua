local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd)
package.path = cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua;" .. package.path

local relops = require("relops")
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

local function blank_lines(count)
  local result = {}

  for _ = 1, count do
    table.insert(result, "")
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

test("change deletes the remote range and returns after insert abort", function()
  reset(15, { 8, 0 })

  feed("crr2j3j<Esc>")

  eq(buffer_lines(), without_range(15, 10, 11), "change should remove the selected range")
  eq(vim.api.nvim_win_get_cursor(0), { 8, 0 }, "change should restore the original cursor after InsertLeave")
  eq(vim.api.nvim_get_mode().mode, "n", "change should finish in normal mode after escape")
end)

test("single move clears the source and inserts content at the destination coordinate", function()
  reset(15, { 10, 0 })

  feed("mr2j5j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 11), { "" }, range_lines(13, 14), { "L12", "L15" }),
    "single move should clear source and shift destination content down"
  )
  eq(register_lines("1"), { "L12" }, "move should set delete-like register")
end)

test("single move preserves destination content by shifting it down", function()
  reset(7, { 1, 0 })

  vim.api.nvim_buf_set_lines(0, 3, 4, false, { "L4 text" })

  feed("mr3j6j")

  eq(
    buffer_lines(),
    { "L1", "L2", "L3", "", "L5", "L6", "L4 text", "L7" },
    "single move should insert captured content at the destination coordinate"
  )
end)

test("range move clears the source and inserts content at the destination coordinate", function()
  reset(30, { 10, 0 })

  feed("mrr2j3j13j")

  eq(
    buffer_lines(),
    concat(
      range_lines(1, 11),
      blank_lines(2),
      range_lines(14, 22),
      range_lines(12, 13),
      range_lines(23, 30)
    ),
    "range move should clear source and shift destination content down"
  )
  eq(register_lines("1"), { "L12", "L13" }, "range move should set delete-like register")
end)

test("range move preserves destination content by shifting it down", function()
  reset(20, { 10, 0 })

  feed("mrr2j5j6j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 11), blank_lines(4), range_lines(12, 20)),
    "range move should insert captured content and shift destination content down"
  )
end)

test("range move extends the buffer to preserve shifted destination content", function()
  reset(7, { 1, 0 })

  feed("mrr3j4j6j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 3), blank_lines(2), { "L6", "L4", "L5", "L7" }),
    "range move should grow the buffer instead of dropping shifted content"
  )
end)

test("range move allows destination overlap with the source range", function()
  reset(15, { 5, 0 })

  feed("mrr2j4j3j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 6), { "", "L7", "L8", "L9", "", "" }, range_lines(10, 15)),
    "overlapping range move should capture source before clearing and inserting"
  )
end)

test("move-to-current moves a single remote line to the cursor", function()
  reset(15, { 10, 0 })

  feed("mr3j0")

  eq(
    buffer_lines(),
    concat(range_lines(1, 9), { "L13" }, range_lines(10, 12), { "" }, range_lines(14, 15)),
    "move-to-current should insert before the cursor line"
  )
end)

test("move accepts current-line token as a destination coordinate", function()
  reset(15, { 10, 0 })

  feed("mr3k0")

  eq(
    buffer_lines(),
    concat(range_lines(1, 6), { "" }, range_lines(8, 9), { "L7" }, range_lines(10, 15)),
    "current-line destination token should land at the original cursor coordinate"
  )
end)

test("move accepts current-line token as the second source endpoint", function()
  reset(15, { 10, 0 })

  feed("mrr3k02j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 6), blank_lines(4), { "L11" }, range_lines(7, 10), range_lines(12, 15)),
    "source range should support distant target through the cursor line"
  )
end)

test("move accepts source range through current line with a remote destination", function()
  reset(20, { 10, 0 })

  feed("mrr5j09k")

  eq(
    buffer_lines(),
    concat(range_lines(10, 15), range_lines(1, 9), blank_lines(6), range_lines(16, 20)),
    "source range should support below target through the cursor line"
  )
end)

test("move overlap does not notify or mutate incorrectly", function()
  reset(15, { 5, 0 }, { notifications = true })

  feed("mrr2j4j3j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 6), { "", "L7", "L8", "L9", "", "" }, range_lines(10, 15)),
    "move into source range should be allowed"
  )
  ok(not has_notification("Move destination cannot be inside the source range"), "overlapping move should not error")
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
    concat(range_lines(1, 9), { "L13" }, range_lines(10, 12), { "" }, range_lines(14, 15)),
    "move should mutate before undo"
  )

  feed("u")
  eq(buffer_lines(), lines(15), "undo should restore moved lines")
  eq(vim.api.nvim_win_get_cursor(0), { 10, 0 }, "undo wrapper should restore cursor after move")

  feed("<C-r>")
  eq(
    buffer_lines(),
    concat(range_lines(1, 9), { "L13" }, range_lines(10, 12), { "" }, range_lines(14, 15)),
    "redo should reapply move"
  )
  eq(vim.api.nvim_win_get_cursor(0), { 10, 0 }, "redo wrapper should restore cursor after move")
end)

test("repeated setup removes old relops mappings", function()
  reset(5, { 3, 0 })

  relops.setup({
    notifications = false,
    yank_highlight = { enabled = false },
    mappings = { enabled = true, delete = "zx", yank = false, change = false, move = false },
  })
  ok(vim.fn.maparg("zx", "n") ~= "", "custom mapping should exist")

  relops.setup({ mappings = { enabled = false }, notifications = false })
  eq(vim.fn.maparg("zx", "n"), "", "custom mapping should be removed on disabled setup")
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
