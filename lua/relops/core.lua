local M = {}

local function relops_dir_to_mult(dir)
  if dir == "j" then
    return 1
  elseif dir == "k" then
    return -1
  end

  return nil
end

local function relops_pattern_escape(value)
  return (value:gsub("([^%w])", "%%%1"))
end

local function relops_buf_line_count(bufnr)
  return vim.api.nvim_buf_line_count(bufnr)
end

local function relops_count_pattern(capture)
  if capture then
    return "([1-9]%d*)"
  end

  return "[1-9]%d*"
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

M.buf_line_count = relops_buf_line_count
M.count_pattern = relops_count_pattern
M.pattern_escape = relops_pattern_escape
M.relative_lnum = relops_relative_lnum
M.compute_range = relops_compute_range
M.range_valid = relops_range_valid

return M
