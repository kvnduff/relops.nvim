local M = {}

local default_config = {
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
}

local config = vim.deepcopy(default_config)
local state_ns = vim.api.nvim_create_namespace("relops_state")
local flash_ns = vim.api.nvim_create_namespace("relops_flash")

local mapping_descriptions = {
  delete = "Relops: delete remote relative range",
  yank = "Relops: yank remote relative range",
  change = "Relops: change remote relative range",
  move = "Relops: move remote relative range",
  undo = "Relops: undo, preserving remote-relative position when needed",
  redo = "Relops: redo, preserving remote-relative position when needed",
}

local active_mappings = {}

local function notify(message, level)
  if config.notifications then
    vim.notify("relops.nvim: " .. message, level or vim.log.levels.INFO, {
      title = "relops.nvim",
    })
  end
end

local function relops_buf_line_count(bufnr)
  return vim.api.nvim_buf_line_count(bufnr)
end

local function relops_clamp_lnum_col(bufnr, lnum, col)
  local last = relops_buf_line_count(bufnr)
  lnum = math.max(1, math.min(lnum, last))

  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  col = math.max(0, math.min(col or 0, #line))

  return lnum, col
end

local function relops_set_view(bufnr, lnum, col, screen_offset)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end

  lnum, col = relops_clamp_lnum_col(bufnr, lnum, col)

  local view = vim.fn.winsaveview()
  view.lnum = lnum
  view.col = col
  view.curswant = col

  if screen_offset then
    view.topline = math.max(1, lnum - screen_offset)
  end

  vim.fn.winrestview(view)
end

local function relops_dir_to_mult(dir)
  if dir == "j" then
    return 1
  elseif dir == "k" then
    return -1
  end

  return nil
end

local function relops_relative_lnum(cur_lnum, n, dir)
  local mult = relops_dir_to_mult(dir)

  if not mult then
    return nil
  end

  return cur_lnum + mult * n
end

local function relops_compute_range(cur_lnum, n1, dir1, n2, dir2)
  local l1 = relops_relative_lnum(cur_lnum, n1, dir1)
  local l2 = relops_relative_lnum(cur_lnum, n2, dir2)

  if not l1 or not l2 then
    return nil
  end

  return {
    lnum1 = l1,
    lnum2 = l2,
    start_lnum = math.min(l1, l2),
    end_lnum = math.max(l1, l2),
  }
end

local function relops_range_valid(bufnr, range)
  local last = relops_buf_line_count(bufnr)
  return range.start_lnum >= 1 and range.end_lnum <= last
end

local function set_linewise_register(reg, lines)
  pcall(function()
    vim.fn.setreg(reg, lines, "V")
  end)
end

local function relops_set_delete_like_registers(lines)
  if config.clipboard.unnamed then
    set_linewise_register('"', lines)
  end

  if config.clipboard.delete_register then
    set_linewise_register("1", lines)
  end

  if config.clipboard.system then
    set_linewise_register("+", lines)
  end

  if config.clipboard.selection then
    set_linewise_register("*", lines)
  end
end

local function relops_set_yank_like_registers(lines)
  if config.clipboard.unnamed then
    set_linewise_register('"', lines)
  end

  if config.clipboard.yank_register then
    set_linewise_register("0", lines)
  end

  if config.clipboard.system then
    set_linewise_register("+", lines)
  end

  if config.clipboard.selection then
    set_linewise_register("*", lines)
  end
end

local function relops_flash_range(bufnr, start_lnum, end_lnum)
  if not config.yank_highlight.enabled then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, flash_ns, 0, -1)

  for lnum = start_lnum, end_lnum do
    vim.api.nvim_buf_set_extmark(bufnr, flash_ns, lnum - 1, 0, {
      line_hl_group = config.yank_highlight.group,
      hl_eol = true,
    })
  end

  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, flash_ns, 0, -1)
    end
  end, config.yank_highlight.duration)
end

local function relops_make_state(bufnr, view, cur_lnum, cur_col, opts)
  opts = opts or {}

  local state = {
    bufnr = bufnr,
    ns = state_ns,
    cursor_screen_offset = cur_lnum - view.topline,
    orig_lnum = cur_lnum,
    orig_col = cur_col,
    post_lnum = opts.post_lnum or cur_lnum,
    post_col = opts.post_col or cur_col,
    undo_lnum = opts.undo_lnum or cur_lnum,
    undo_col = opts.undo_col or cur_col,
    redo_lnum = opts.redo_lnum or (opts.post_lnum or cur_lnum),
    redo_col = opts.redo_col or (opts.post_col or cur_col),
    use_extmark = opts.use_extmark or false,
  }

  if state.use_extmark then
    state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, state_ns, cur_lnum - 1, cur_col, {
      right_gravity = false,
    })
  end

  vim.b.relops_state = state
end

local function relops_restore_state(which)
  local state = vim.b.relops_state

  if not state then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  if state.bufnr ~= bufnr then
    return
  end

  if state.use_extmark and state.extmark_id then
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns, state.extmark_id, {})

    if mark and mark[1] ~= nil then
      relops_set_view(bufnr, mark[1] + 1, mark[2], state.cursor_screen_offset)
      return
    end
  end

  local lnum, col

  if which == "undo" then
    lnum, col = state.undo_lnum, state.undo_col
  elseif which == "redo" then
    lnum, col = state.redo_lnum, state.redo_col
  else
    lnum, col = state.post_lnum, state.post_col
  end

  relops_set_view(bufnr, lnum, col, state.cursor_screen_offset)
end

local function relops_undo()
  local should_restore = vim.b.relops_restore_on_next_undo

  vim.cmd("silent! normal! " .. vim.v.count1 .. "u")

  if should_restore then
    vim.b.relops_restore_on_next_undo = false
    vim.b.relops_restore_on_next_redo = true
    relops_restore_state("undo")
  end
end

local function relops_redo()
  local should_restore = vim.b.relops_restore_on_next_redo

  vim.cmd("silent! normal! " .. vim.v.count1 .. "\018")

  if should_restore then
    vim.b.relops_restore_on_next_redo = false
    vim.b.relops_restore_on_next_undo = true
    relops_restore_state("redo")
  end
end

local function relops_read_range()
  local chars = ""

  while true do
    local ch = vim.fn.getcharstr()

    if ch == "\027" or ch == "\003" then
      return nil
    end

    chars = chars .. ch

    local first, dir1, second, dir2 = chars:match("^(%d+)([jk])(%d+)([jk])$")

    if first and dir1 and second and dir2 then
      return tonumber(first), dir1, tonumber(second), dir2
    end

    local single, d1, d2 = chars:match("^(%d+)([jk])([jk])$")

    if single and d1 and d2 and d1 == d2 then
      return tonumber(single), d1, tonumber(single), d2
    end

    if
      not chars:match("^%d*$")
      and not chars:match("^%d+[jk]$")
      and not chars:match("^%d+[jk]%d*$")
    then
      notify("Invalid range: " .. chars, vim.log.levels.ERROR)
      return nil
    end

    if #chars > 24 then
      notify("Range is too long: " .. chars, vim.log.levels.ERROR)
      return nil
    end
  end
end

local function relops_read_move()
  local chars = ""

  while true do
    local ch = vim.fn.getcharstr()

    if ch == "\027" or ch == "\003" then
      return nil
    end

    chars = chars .. ch

    local a, d1, b, d2, c, d3 = chars:match("^(%d+)([jk])(%d+)([jk])(%d+)([jk])$")

    if a and d1 and b and d2 and c and d3 then
      return {
        source_n1 = tonumber(a),
        source_dir1 = d1,
        source_n2 = tonumber(b),
        source_dir2 = d2,
        dest_n = tonumber(c),
        dest_dir = d3,
        dest_here = false,
      }
    end

    local s, sd1, sd2, destn, destd = chars:match("^(%d+)([jk])([jk])(%d+)([jk])$")

    if s and sd1 and sd2 and destn and destd and sd1 == sd2 then
      return {
        source_n1 = tonumber(s),
        source_dir1 = sd1,
        source_n2 = tonumber(s),
        source_dir2 = sd2,
        dest_n = tonumber(destn),
        dest_dir = destd,
        dest_here = false,
      }
    end

    local ha, hd1, hb, hd2, hd3 = chars:match("^(%d+)([jk])(%d+)([jk])([jk])$")

    if ha and hd1 and hb and hd2 and hd3 and hd2 == hd3 then
      return {
        source_n1 = tonumber(ha),
        source_dir1 = hd1,
        source_n2 = tonumber(hb),
        source_dir2 = hd2,
        dest_here = true,
      }
    end

    local hs, hsd1, hsd2, hsd3 = chars:match("^(%d+)([jk])([jk])([jk])$")

    if hs and hsd1 and hsd2 and hsd3 and hsd1 == hsd2 and hsd2 == hsd3 then
      return {
        source_n1 = tonumber(hs),
        source_dir1 = hsd1,
        source_n2 = tonumber(hs),
        source_dir2 = hsd2,
        dest_here = true,
      }
    end

    if
      not chars:match("^%d*$")
      and not chars:match("^%d+[jk]$")
      and not chars:match("^%d+[jk]%d*$")
      and not chars:match("^%d+[jk][jk]$")
      and not chars:match("^%d+[jk][jk]%d*$")
      and not chars:match("^%d+[jk]%d+[jk]$")
      and not chars:match("^%d+[jk]%d+[jk]%d*$")
    then
      notify("Invalid move: " .. chars, vim.log.levels.ERROR)
      return nil
    end

    if #chars > 32 then
      notify("Move is too long: " .. chars, vim.log.levels.ERROR)
      return nil
    end
  end
end

local function relops_yank()
  local n1, dir1, n2, dir2 = relops_read_range()

  if not n1 then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cur_lnum = vim.api.nvim_win_get_cursor(0)[1]

  local range = relops_compute_range(cur_lnum, n1, dir1, n2, dir2)

  if not range or not relops_range_valid(bufnr, range) then
    notify("Range is outside the buffer", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, range.start_lnum - 1, range.end_lnum, false)

  if #lines == 0 then
    return
  end

  relops_set_yank_like_registers(lines)
  relops_flash_range(bufnr, range.start_lnum, range.end_lnum)
  notify("Yanked " .. #lines .. " remote lines")
end

local function relops_delete()
  local n1, dir1, n2, dir2 = relops_read_range()

  if not n1 then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local view = vim.fn.winsaveview()
  local cur = vim.api.nvim_win_get_cursor(0)
  local cur_lnum, cur_col = cur[1], cur[2]

  local range = relops_compute_range(cur_lnum, n1, dir1, n2, dir2)

  if not range or not relops_range_valid(bufnr, range) then
    notify("Range is outside the buffer", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, range.start_lnum - 1, range.end_lnum, false)

  if #lines == 0 then
    return
  end

  relops_set_delete_like_registers(lines)

  local includes_cursor = range.start_lnum <= cur_lnum and range.end_lnum >= cur_lnum
  local post_lnum, post_col

  if includes_cursor then
    local future_last = math.max(1, relops_buf_line_count(bufnr) - #lines)
    post_lnum = math.min(range.start_lnum, future_last)
    post_col = 0
  else
    post_lnum, post_col = cur_lnum, cur_col
  end

  relops_make_state(bufnr, view, cur_lnum, cur_col, {
    use_extmark = not includes_cursor,
    post_lnum = post_lnum,
    post_col = post_col,
    undo_lnum = cur_lnum,
    undo_col = cur_col,
    redo_lnum = post_lnum,
    redo_col = post_col,
  })

  vim.b.relops_restore_on_next_undo = true
  vim.b.relops_restore_on_next_redo = false

  vim.api.nvim_buf_set_lines(bufnr, range.start_lnum - 1, range.end_lnum, false, {})

  relops_restore_state("post")
  notify("Deleted " .. #lines .. " remote lines")
end

local function relops_change()
  local n1, dir1, n2, dir2 = relops_read_range()

  if not n1 then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local view = vim.fn.winsaveview()
  local cur = vim.api.nvim_win_get_cursor(0)
  local cur_lnum, cur_col = cur[1], cur[2]

  local range = relops_compute_range(cur_lnum, n1, dir1, n2, dir2)

  if not range or not relops_range_valid(bufnr, range) then
    notify("Range is outside the buffer", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, range.start_lnum - 1, range.end_lnum, false)

  if #lines == 0 then
    return
  end

  relops_set_delete_like_registers(lines)

  local includes_cursor = range.start_lnum <= cur_lnum and range.end_lnum >= cur_lnum

  relops_make_state(bufnr, view, cur_lnum, cur_col, {
    use_extmark = not includes_cursor,
    post_lnum = cur_lnum,
    post_col = cur_col,
    undo_lnum = cur_lnum,
    undo_col = cur_col,
    redo_lnum = cur_lnum,
    redo_col = cur_col,
  })

  vim.api.nvim_buf_set_lines(bufnr, range.start_lnum - 1, range.end_lnum, false, {})

  local last = relops_buf_line_count(bufnr)
  local insert_lnum = math.min(range.start_lnum, last)
  insert_lnum = math.max(1, insert_lnum)

  relops_set_view(bufnr, insert_lnum, 0, nil)

  local group = vim.api.nvim_create_augroup("RelopsChangeOnce", { clear = false })
  local autocmd_id

  autocmd_id = vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_autocmd, autocmd_id)

      vim.b.relops_restore_on_next_undo = true
      vim.b.relops_restore_on_next_redo = false

      relops_restore_state("post")
    end,
  })

  vim.cmd("startinsert")
end

local function relops_move()
  local move = relops_read_move()

  if not move then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local view = vim.fn.winsaveview()
  local cur = vim.api.nvim_win_get_cursor(0)
  local cur_lnum, cur_col = cur[1], cur[2]

  local src = relops_compute_range(
    cur_lnum,
    move.source_n1,
    move.source_dir1,
    move.source_n2,
    move.source_dir2
  )

  if not src or not relops_range_valid(bufnr, src) then
    notify("Source range is outside the buffer", vim.log.levels.ERROR)
    return
  end

  local dest_lnum

  if move.dest_here then
    dest_lnum = cur_lnum
  else
    dest_lnum = relops_relative_lnum(cur_lnum, move.dest_n, move.dest_dir)
  end

  if not dest_lnum then
    notify("Invalid move destination", vim.log.levels.ERROR)
    return
  end

  local last = relops_buf_line_count(bufnr)

  if dest_lnum < 1 or dest_lnum > last then
    notify("Move destination is outside the buffer", vim.log.levels.ERROR)
    return
  end

  if dest_lnum >= src.start_lnum and dest_lnum <= src.end_lnum then
    notify("Move destination cannot be inside the source range", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, src.start_lnum - 1, src.end_lnum, false)

  if #lines == 0 then
    return
  end

  relops_set_delete_like_registers(lines)

  local includes_cursor = src.start_lnum <= cur_lnum and src.end_lnum >= cur_lnum
  local insert_index = dest_lnum - 1

  if src.end_lnum < dest_lnum then
    insert_index = insert_index - #lines
  end

  insert_index = math.max(0, math.min(insert_index, relops_buf_line_count(bufnr) - #lines))

  local moved_start_lnum = insert_index + 1
  local post_lnum, post_col

  if includes_cursor then
    post_lnum = moved_start_lnum
    post_col = 0
  else
    post_lnum, post_col = cur_lnum, cur_col
  end

  relops_make_state(bufnr, view, cur_lnum, cur_col, {
    use_extmark = not includes_cursor,
    post_lnum = post_lnum,
    post_col = post_col,
    undo_lnum = cur_lnum,
    undo_col = cur_col,
    redo_lnum = post_lnum,
    redo_col = post_col,
  })

  vim.b.relops_restore_on_next_undo = true
  vim.b.relops_restore_on_next_redo = false

  vim.api.nvim_buf_set_lines(bufnr, src.start_lnum - 1, src.end_lnum, false, {})
  vim.api.nvim_buf_set_lines(bufnr, insert_index, insert_index, false, lines)

  relops_restore_state("post")
  notify("Moved " .. #lines .. " remote lines")
end

local function expect_table(path, value)
  if value ~= nil and type(value) ~= "table" then
    error("relops.setup(): " .. path .. " must be a table", 3)
  end
end

local function expect_boolean(path, value)
  if value ~= nil and type(value) ~= "boolean" then
    error("relops.setup(): " .. path .. " must be a boolean", 3)
  end
end

local function expect_number(path, value)
  if value ~= nil and type(value) ~= "number" then
    error("relops.setup(): " .. path .. " must be a number", 3)
  end
end

local function expect_string(path, value)
  if value ~= nil and type(value) ~= "string" then
    error("relops.setup(): " .. path .. " must be a string", 3)
  end
end

local function expect_mapping(path, value)
  if value == nil or value == false then
    return
  end

  if type(value) ~= "string" then
    error("relops.setup(): " .. path .. " must be a string, false, or nil", 3)
  end
end

local function validate_opts(opts)
  if opts == nil then
    return
  end

  if type(opts) ~= "table" then
    error("relops.setup() expects a table or nil", 3)
  end

  expect_boolean("default_mappings", opts.default_mappings)
  expect_table("mappings", opts.mappings)
  expect_table("yank_highlight", opts.yank_highlight)
  expect_table("clipboard", opts.clipboard)
  expect_table("undo", opts.undo)
  expect_boolean("notifications", opts.notifications)

  if opts.mappings then
    expect_boolean("mappings.enabled", opts.mappings.enabled)
    expect_mapping("mappings.delete", opts.mappings.delete)
    expect_mapping("mappings.yank", opts.mappings.yank)
    expect_mapping("mappings.change", opts.mappings.change)
    expect_mapping("mappings.move", opts.mappings.move)
  end

  if opts.yank_highlight then
    expect_boolean("yank_highlight.enabled", opts.yank_highlight.enabled)
    expect_string("yank_highlight.group", opts.yank_highlight.group)
    expect_number("yank_highlight.duration", opts.yank_highlight.duration)
  end

  if opts.clipboard then
    expect_boolean("clipboard.unnamed", opts.clipboard.unnamed)
    expect_boolean("clipboard.yank_register", opts.clipboard.yank_register)
    expect_boolean("clipboard.delete_register", opts.clipboard.delete_register)
    expect_boolean("clipboard.system", opts.clipboard.system)
    expect_boolean("clipboard.selection", opts.clipboard.selection)
  end

  if opts.undo then
    expect_boolean("undo.wrap", opts.undo.wrap)
  end
end

local function merged_config(opts)
  validate_opts(opts)

  opts = opts or {}

  local merged = vim.tbl_deep_extend("force", vim.deepcopy(default_config), opts)

  if opts.default_mappings ~= nil and (not opts.mappings or opts.mappings.enabled == nil) then
    merged.mappings.enabled = opts.default_mappings
  end

  return merged
end

local function mapping_is_ours(name, lhs)
  local ok, map = pcall(vim.fn.maparg, lhs, "n", false, true)

  if not ok or type(map) ~= "table" or not map.lhs or map.lhs == "" then
    return false
  end

  if map.desc == nil or map.desc == "" then
    return true
  end

  return map.desc == mapping_descriptions[name]
end

local function unmap(name)
  local lhs = active_mappings[name]

  if not lhs then
    return
  end

  if mapping_is_ours(name, lhs) then
    pcall(vim.keymap.del, "n", lhs)
  end

  active_mappings[name] = nil
end

local function map_if_set(name, lhs, rhs)
  unmap(name)

  if lhs == nil or lhs == false or lhs == "" then
    return
  end

  vim.keymap.set("n", lhs, rhs, {
    noremap = true,
    silent = true,
    desc = mapping_descriptions[name],
  })

  active_mappings[name] = lhs
end

function M.setup(opts)
  config = merged_config(opts)

  if config.mappings.enabled ~= false then
    map_if_set("delete", config.mappings.delete, M.delete)
    map_if_set("yank", config.mappings.yank, M.yank)
    map_if_set("change", config.mappings.change, M.change)
    map_if_set("move", config.mappings.move, M.move)
  else
    unmap("delete")
    unmap("yank")
    unmap("change")
    unmap("move")
  end

  if config.undo.wrap ~= false then
    map_if_set("undo", "u", M.undo)
    map_if_set("redo", "<C-r>", M.redo)
  else
    unmap("undo")
    unmap("redo")
  end

  return M
end

M.delete = relops_delete
M.yank = relops_yank
M.change = relops_change
M.move = relops_move
M.undo = relops_undo
M.redo = relops_redo
M.defaults = vim.deepcopy(default_config)

return M
