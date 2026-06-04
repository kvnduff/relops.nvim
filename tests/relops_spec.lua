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

test("delete parses a real mapping range and sets delete registers", function()
  reset(20, { 10, 0 })

  feed("dr2j4j")

  eq(buffer_lines(), without_range(20, 12, 14), "delete should remove 12..14")
  eq(vim.api.nvim_win_get_cursor(0), { 10, 0 }, "delete should keep cursor anchored")
  eq(register_lines('"'), { "L12", "L13", "L14" }, "unnamed register should receive deleted lines")
  eq(register_lines("1"), { "L12", "L13", "L14" }, "delete register should receive deleted lines")
end)

test("yank supports mixed above and below ranges", function()
  reset(20, { 10, 0 })

  feed("yr2k3j")

  eq(buffer_lines(), lines(20), "yank should not mutate buffer")
  eq(register_lines('"'), { "L8", "L9", "L10", "L11", "L12", "L13" }, "unnamed register should receive yanked lines")
  eq(register_lines("0"), { "L8", "L9", "L10", "L11", "L12", "L13" }, "yank register should receive yanked lines")
end)

test("single-line shorthand works for ranges", function()
  reset(20, { 10, 0 })

  feed("yr3kk")

  eq(register_lines('"'), { "L7" }, "single-line shorthand should target one line")
  eq(register_lines("0"), { "L7" }, "yank register should receive shorthand line")
end)

test("change deletes the remote range and returns after insert abort", function()
  reset(15, { 8, 0 })

  feed("cr2j3j<Esc>")

  eq(buffer_lines(), without_range(15, 10, 11), "change should remove the selected range")
  eq(vim.api.nvim_win_get_cursor(0), { 8, 0 }, "change should restore the original cursor after InsertLeave")
  eq(vim.api.nvim_get_mode().mode, "n", "change should finish in normal mode after escape")
end)

test("explicit move inserts before the destination", function()
  reset(30, { 10, 0 })

  feed("mr2j3j13j")

  eq(
    buffer_lines(),
    concat(range_lines(1, 11), range_lines(14, 22), range_lines(12, 13), range_lines(23, 30)),
    "move should insert source before destination"
  )
  eq(register_lines("1"), { "L12", "L13" }, "move should set delete-like register")
end)

test("move-to-here shorthand moves a single remote line to the cursor", function()
  reset(15, { 10, 0 })

  feed("mr3jjj")

  eq(
    buffer_lines(),
    concat(range_lines(1, 9), { "L13" }, range_lines(10, 12), range_lines(14, 15)),
    "move-to-here shorthand should insert before the cursor line"
  )
end)

test("out-of-buffer ranges do not mutate buffers", function()
  reset(10, { 5, 0 }, { notifications = true })

  feed("dr99j100j")

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

test("move into source range is rejected", function()
  reset(15, { 5, 0 }, { notifications = true })

  feed("mr2j4j3j")

  eq(buffer_lines(), lines(15), "move into source range should not mutate")
  ok(has_notification("Move destination cannot be inside the source range"), "move into source should notify")
end)

test("undo and redo wrappers restore buffer and cursor when enabled", function()
  reset(20, { 10, 0 }, { undo = { wrap = true } })

  feed("dr2j4j")
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

  feed("mr3jjj")
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
