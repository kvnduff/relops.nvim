local M = {}

local core = require("relops.core")

local preview_ns = vim.api.nvim_create_namespace("relops_preview")
local dir_hint = "<count>j / <count>k"

local config
local preview_win
local preview_buf

function M.configure(values)
  config = values
end

local function relops_preview_stages(op)
  local count = core.count_pattern(true)
  local current = core.pattern_escape(config.syntax.current_line)
  local dir_hint_current = dir_hint .. " / " .. config.syntax.current_line

  if op == "move" then
    return {
      {
        pattern = "^r" .. count .. "([jk])" .. current .. "$",
        stage = "move_dest",
        hint = dir_hint,
        source_here = true,
      },
      {
        pattern = "^r" .. count .. "([jk])" .. count .. "([jk])$",
        stage = "move_dest",
        hint = dir_hint_current,
      },
      { pattern = "^r" .. count .. "([jk])$", stage = "range_end", hint = dir_hint_current },
      { pattern = "^r$", stage = "range_start", hint = dir_hint },
      {
        pattern = "^" .. count .. "([jk])$",
        stage = "move_dest",
        hint = dir_hint_current,
        single_source = true,
      },
      { pattern = "^$", stage = "target", hint = dir_hint },
    }
  end

  return {
    { pattern = "^r" .. count .. "([jk])$", stage = "range_end", hint = dir_hint_current },
    { pattern = "^r$", stage = "range_start", hint = dir_hint },
    { pattern = "^$", stage = "target", hint = dir_hint },
  }
end

local function relops_preview_tokens(chars, pattern)
  local matched = { chars:match(pattern) }

  if matched[1] == nil then
    return nil
  end

  local tokens = {}

  for _, value in ipairs(matched) do
    if value:match("^%d+$") or value == "j" or value == "k" then
      tokens[#tokens + 1] = value
    end
  end

  return tokens
end

local function relops_preview_locked(tokens, entry)
  local locked = {}

  if tokens[1] then
    locked.n1 = tonumber(tokens[1])
    locked.dir1 = tokens[2]
  end

  if tokens[3] then
    locked.n2 = tonumber(tokens[3])
    locked.dir2 = tokens[4]
  end

  if entry.single_source then
    locked.n2 = locked.n1
    locked.dir2 = locked.dir1
  elseif entry.source_here then
    locked.n2 = 0
    locked.dir2 = "j"
  end

  return locked
end

local function relops_preview_state(op, chars)
  local pending = chars:match("([1-9]%d*)$")

  if pending then
    chars = chars:sub(1, #chars - #pending)
    pending = tonumber(pending)
  end

  for _, entry in ipairs(relops_preview_stages(op)) do
    local tokens = relops_preview_tokens(chars, entry.pattern)

    if tokens then
      return {
        stage = entry.stage,
        pending = pending,
        locked = relops_preview_locked(tokens, entry),
        hint = pending and dir_hint or entry.hint,
      }
    end
  end

  return nil
end

local function relops_preview_offset(n, dir)
  if n == 0 then
    return config.syntax.current_line
  end

  return n .. dir
end

local function relops_preview_edge_virt(bufnr, lnum)
  if lnum < 1 then
    return "past start of buffer (line 1)"
  end

  local last = core.buf_line_count(bufnr)

  if lnum > last then
    return "past end of buffer (line " .. last .. ")"
  end

  return nil
end

local function relops_preview_line_row(bufnr, dir, offset, lnum)
  local virt = relops_preview_edge_virt(bufnr, lnum)

  if virt then
    return { dir = dir, offset = offset, dim = true, virt = virt }
  end

  return {
    dir = dir,
    offset = offset,
    lnum = lnum,
    text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1],
  }
end

local function relops_preview_range_rows(bufnr, dir, range, offset1, offset2)
  if not core.range_valid(bufnr, range) then
    if relops_preview_edge_virt(bufnr, range.lnum2) then
      return { relops_preview_line_row(bufnr, dir, offset2, range.lnum2) }
    end

    return { relops_preview_line_row(bufnr, dir, offset1, range.lnum1) }
  end

  local ascending = range.lnum1 <= range.lnum2
  local first_offset = ascending and offset1 or offset2
  local last_offset = ascending and offset2 or offset1
  local rows = { relops_preview_line_row(bufnr, dir, first_offset, range.start_lnum) }

  if range.start_lnum == range.end_lnum then
    return rows
  end

  local hidden = range.end_lnum - range.start_lnum - 1

  if hidden > 0 then
    rows[#rows + 1] = { dir = dir, virt = "… " .. hidden .. " more" }
  end

  rows[#rows + 1] = relops_preview_line_row(bufnr, dir, last_offset, range.end_lnum)

  return rows
end

local function relops_preview_moved_lnum(src, count, lnum)
  if lnum < src.start_lnum then
    return lnum
  end

  return lnum + count
end

local function relops_preview_seam_row(bufnr, dir, offset, seam, lnum, source_lnum)
  if lnum < 1 then
    return { dir = dir, offset = offset, seam = seam, virt = "(start of buffer)" }
  end

  return {
    dir = dir,
    offset = offset,
    seam = seam,
    lnum = lnum,
    text = vim.api.nvim_buf_get_lines(bufnr, source_lnum - 1, source_lnum, false)[1],
  }
end

local function relops_preview_move_rows(bufnr, cur_lnum, locked, dir, pending)
  local src = core.compute_range(cur_lnum, locked.n1, locked.dir1, locked.n2, locked.dir2)

  if not core.range_valid(bufnr, src) then
    return relops_preview_range_rows(
      bufnr,
      dir,
      src,
      relops_preview_offset(locked.n1, locked.dir1),
      relops_preview_offset(locked.n2, locked.dir2)
    )
  end

  local offset = relops_preview_offset(pending, dir)
  local dest_lnum = core.relative_lnum(cur_lnum, pending, dir)

  if relops_preview_edge_virt(bufnr, dest_lnum) then
    return { relops_preview_line_row(bufnr, dir, offset, dest_lnum) }
  end

  if dest_lnum >= src.start_lnum and dest_lnum <= src.end_lnum then
    return { { dir = dir, offset = offset, dim = true, virt = "(inside the source range)" } }
  end

  local count = src.end_lnum - src.start_lnum + 1
  local insert_lnum = dest_lnum > src.end_lnum and dest_lnum - count or dest_lnum

  return {
    relops_preview_seam_row(
      bufnr,
      dir,
      offset,
      "above",
      insert_lnum - 1,
      relops_preview_moved_lnum(src, count, insert_lnum - 1)
    ),
    relops_preview_seam_row(
      bufnr,
      dir,
      offset,
      "below",
      insert_lnum + count,
      relops_preview_moved_lnum(src, count, insert_lnum)
    ),
  }
end

local function relops_preview_pending_rows(bufnr, cur_lnum, state, dir)
  local locked = state.locked

  if state.stage == "move_dest" then
    return relops_preview_move_rows(bufnr, cur_lnum, locked, dir, state.pending)
  end

  local offset = relops_preview_offset(state.pending, dir)

  if state.stage == "range_end" then
    local range = core.compute_range(cur_lnum, locked.n1, locked.dir1, state.pending, dir)

    return relops_preview_range_rows(
      bufnr,
      dir,
      range,
      relops_preview_offset(locked.n1, locked.dir1),
      offset
    )
  end

  local lnum = core.relative_lnum(cur_lnum, state.pending, dir)

  return { relops_preview_line_row(bufnr, dir, offset, lnum) }
end

local function relops_preview_locked_rows(bufnr, cur_lnum, locked)
  if not locked.n1 then
    return {}
  end

  local offset1 = relops_preview_offset(locked.n1, locked.dir1)

  if not locked.n2 then
    local lnum = core.relative_lnum(cur_lnum, locked.n1, locked.dir1)

    return { relops_preview_line_row(bufnr, locked.dir1, offset1, lnum) }
  end

  local range = core.compute_range(cur_lnum, locked.n1, locked.dir1, locked.n2, locked.dir2)

  return relops_preview_range_rows(
    bufnr,
    locked.dir1,
    range,
    offset1,
    relops_preview_offset(locked.n2, locked.dir2)
  )
end

local function relops_preview_split(rows)
  for index, row in ipairs(rows) do
    if row.dir == "j" then
      return index - 1
    end
  end

  return #rows
end

local function relops_preview_model(bufnr, cur_lnum, op, chars)
  local state = relops_preview_state(op, chars)

  if not state then
    return nil
  end

  local rows

  if state.pending then
    rows = {}

    for _, dir in ipairs({ "k", "j" }) do
      vim.list_extend(rows, relops_preview_pending_rows(bufnr, cur_lnum, state, dir))
    end
  else
    rows = relops_preview_locked_rows(bufnr, cur_lnum, state.locked)
  end

  return {
    expr = (config.mappings[op] or "") .. chars,
    label = op,
    hint = state.hint,
    rows = rows,
    split = relops_preview_split(rows),
  }
end

local function relops_preview_buf()
  if not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then
    preview_buf = vim.api.nvim_create_buf(false, true)
  end

  return preview_buf
end

local function relops_preview_pad(value, width)
  return string.rep(" ", math.max(width - #value, 0)) .. value
end

local function relops_preview_cells(row)
  return {
    row.dir or "",
    row.offset or "",
    row.seam or "",
    row.lnum and tostring(row.lnum) or "",
  }
end

local function relops_preview_widths(rows)
  local widths = { 0, 0, 0, 0 }

  for _, row in ipairs(rows) do
    for index, cell in ipairs(relops_preview_cells(row)) do
      widths[index] = math.max(widths[index], #cell)
    end
  end

  return widths
end

local function relops_preview_columns_width(widths)
  local width = widths[1] + widths[2] + widths[4] + 2

  if widths[3] > 0 then
    width = width + widths[3] + 1
  end

  return width
end

local function relops_preview_escape(value)
  return (value:gsub("%%", "%%%%"))
end

local function relops_preview_column(group, value, width)
  return "%#" .. group .. "#" .. relops_preview_escape(relops_preview_pad(value, width))
end

local function relops_preview_gutter_text(row, widths)
  local cells = relops_preview_cells(row)
  local columns = {
    relops_preview_column(config.preview.label_group, cells[1], widths[1]),
    relops_preview_column(config.preview.number_group, cells[2], widths[2]),
  }

  if widths[3] > 0 then
    columns[#columns + 1] = relops_preview_column(config.preview.hint_group, cells[3], widths[3])
  end

  columns[#columns + 1] = relops_preview_column(config.preview.number_group, cells[4], widths[4])

  return table.concat(columns, " ") .. " %#" .. config.preview.hint_group .. "#│ "
end

local function relops_preview_label_text(label, widths)
  local group = config.preview.expression_group
  local column = relops_preview_column(group, label, relops_preview_columns_width(widths))

  return column .. " %#" .. group .. "#┈ "
end

local function relops_preview_mark(bufnr, lnum, virt, dim)
  local opts = {}

  if virt then
    opts.virt_text = { { virt, config.preview.hint_group } }
  end

  if dim then
    opts.line_hl_group = config.preview.hint_group
  end

  vim.api.nvim_buf_set_extmark(bufnr, preview_ns, lnum, 0, opts)
end

local function relops_preview_expr_mark(bufnr, lnum, expr)
  local rule = expr .. "_ " .. string.rep("┈", vim.o.columns)

  vim.api.nvim_buf_set_extmark(bufnr, preview_ns, lnum, 0, {
    virt_text = { { rule, config.preview.expression_group } },
    line_hl_group = config.preview.expression_group,
  })
end

local function relops_preview_lnum(model, index)
  if index <= model.split then
    return index
  end

  return index + 1
end

local function relops_preview_title(hint)
  return {
    { " relops.nvim ", config.preview.label_group },
    { "· " .. hint .. " ", config.preview.hint_group },
  }
end

local function relops_preview_open(bufnr, height, title)
  local win_config = {
    relative = "editor",
    anchor = "SW",
    row = math.max(vim.o.lines - vim.o.cmdheight - 1, 1),
    col = 0,
    width = math.max(vim.o.columns - 2, 1),
    height = height,
    title = title,
  }

  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    if not pcall(vim.api.nvim_win_set_config, preview_win, win_config) then
      return false
    end
  else
    win_config.style = "minimal"
    win_config.border = config.preview.border
    win_config.focusable = false
    win_config.zindex = 200
    win_config.noautocmd = true

    local opened, win = pcall(vim.api.nvim_open_win, bufnr, false, win_config)

    if not opened then
      return false
    end

    preview_win = win
  end

  vim.api.nvim_win_call(preview_win, function()
    vim.wo.wrap = false
    vim.wo.statuscolumn = "%{%get(b:relops_preview_gutter, v:lnum, '')%}"
  end)

  return true
end

local function relops_preview_show(model, source_bufnr)
  if not config.preview.enabled or not model then
    return
  end

  local bufnr = relops_preview_buf()
  local widths = relops_preview_widths(model.rows)
  local lines = { [model.split + 1] = "" }
  local gutter = {}

  for index, row in ipairs(model.rows) do
    local lnum = relops_preview_lnum(model, index)

    lines[lnum] = row.text or ""
    gutter[tostring(lnum)] = relops_preview_gutter_text(row, widths)
  end

  gutter[tostring(model.split + 1)] = relops_preview_label_text(model.label, widths)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.b[bufnr].relops_preview_gutter = gutter

  local filetype = vim.bo[source_bufnr].filetype

  if vim.bo[bufnr].filetype ~= filetype then
    vim.bo[bufnr].filetype = filetype
  end

  vim.api.nvim_buf_clear_namespace(bufnr, preview_ns, 0, -1)
  relops_preview_expr_mark(bufnr, model.split, model.expr)

  for index, row in ipairs(model.rows) do
    if row.virt or row.dim then
      local lnum = relops_preview_lnum(model, index)

      relops_preview_mark(bufnr, lnum - 1, row.virt, row.dim)
    end
  end

  local max_height = math.max(math.floor(config.preview.max_height), 1)
  local height = math.min(#model.rows + 1, max_height)

  if relops_preview_open(bufnr, height, relops_preview_title(model.hint)) then
    vim.cmd("redraw")
  end
end

local function relops_preview_close()
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    pcall(vim.api.nvim_win_close, preview_win, true)
  end

  preview_win = nil

  if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
    vim.api.nvim_buf_clear_namespace(preview_buf, preview_ns, 0, -1)
    vim.b[preview_buf].relops_preview_gutter = nil
  end
end

local function relops_preview_update(op, chars)
  if not config.preview.enabled then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cur_lnum = vim.api.nvim_win_get_cursor(0)[1]

  pcall(relops_preview_show, relops_preview_model(bufnr, cur_lnum, op, chars), bufnr)
end

M.update = relops_preview_update
M.close = relops_preview_close
M._state = relops_preview_state
M._model = relops_preview_model
M._show = relops_preview_show

return M
