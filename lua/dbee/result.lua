local utils = require("dbee.utils")
local progress = require("dbee.progress")
local ui_helper = require("dbee.ui_helper")

---@alias result_config { mappings: table<string, mapping>, page_size: integer, progress: progress_config }

-- Result represents the part of ui with displayed results
---@class Result
---@field private handler Handler
---@field private winid? integer
---@field private bufnr integer
---@field private current_call call_details
---@field private page_size integer
---@field private page_index integer index of the current page
---@field private page_ammount integer number of pages in the current result set
---@field private stop_progress fun() function that stops progress display
---@field private progress_opts progress_config
local Result = {}

---@param handler Handler
---@param quit_handle? fun()
---@param opts? result_config
---@return Result
function Result:new(handler, quit_handle, opts)
  opts = opts or {}
  quit_handle = quit_handle or function() end

  if not handler then
    error("no Handler passed to Result")
  end

  -- class object
  local o = {
    handler = handler,
    current_call = {},
    page_size = opts.page_size or 100,
    page_index = 0,
    page_ammount = 0,
    stop_progress = function() end,
    progress_opts = opts.progress or {},
  }
  setmetatable(o, self)
  self.__index = self

  -- create a buffer for drawer and configure it
  o.bufnr = ui_helper.create_blank_buffer("dbee-result", {
    buflisted = false,
    bufhidden = "delete",
    buftype = "nofile",
    swapfile = false,
  })
  ui_helper.configure_buffer_mappings(o.bufnr, o:generate_keymap(opts.mappings))
  ui_helper.configure_buffer_quit_handle(o.bufnr, quit_handle)

  handler:register_event_listener("call_state_changed", function(data)
    o:on_call_state_changed(data)
  end)

  return o
end

-- event listener for new calls
---@private
---@param data { call: call_details }
function Result:on_call_state_changed(data)
  local call = data.call

  -- we only care about the current call
  if call.id ~= self.current_call.id then
    return
  end

  -- update the current call with up to date details
  self.current_call = call

  -- perform action based on the state
  if call.state == "executing" then
    self.stop_progress()
    self:display_progress()
  elseif call.state == "retrieving" then
    self.stop_progress()
    self:page_current()
  elseif call.state == "executing_failed" or call.state == "retrieving_failed" or call.state == "canceled" then
    self.stop_progress()
    self:display_status()
  else
    self.stop_progress()
  end
end

---@private
function Result:display_progress()
  self.stop_progress = progress.display(self.bufnr, self.progress_opts)
end

---@private
function Result:display_status()
  local state = self.current_call.state

  local msg = ""
  if state == "executing_failed" then
    msg = "Call execution failed"
  elseif state == "retrieving_failed" then
    msg = "Failed retrieving results"
  elseif state == "canceled" then
    msg = "Call canceled"
  end

  local seconds = self.current_call.time_taken_us / 1000000
  local line = string.format("%s after %.3f seconds", msg, seconds)
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, { line })
end

--- Displays a page of the current result in the results buffer
---@private
---@param page integer zero based page index
---@return integer # current page
function Result:display_result(page)
  -- calculate the ranges
  if page < 0 then
    page = 0
  end
  if page > self.page_ammount then
    page = self.page_ammount
  end
  local from = self.page_size * page
  local to = self.page_size * (page + 1)

  -- call go function
  local length = self.handler:call_display_result(self.current_call.id, self.bufnr, from, to)

  -- adjust page ammount
  self.page_ammount = math.floor(length / self.page_size)
  if length % self.page_size == 0 and self.page_ammount ~= 0 then
    self.page_ammount = self.page_ammount - 1
  end

  -- convert from microseconds to seconds
  local seconds = self.current_call.time_taken_us / 1000000

  -- set winbar status
  if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_win_set_option(
      self.winid,
      "winbar",
      string.format("%d/%d%%=Took %.3fs", page + 1, self.page_ammount + 1, seconds)
    )
  end

  return page
end

---@private
---@param mappings table<string, mapping>
---@return keymap[]
function Result:generate_keymap(mappings)
  mappings = mappings or {}
  return {
    {
      action = function()
        self:page_next()
      end,
      mapping = mappings["page_next"],
    },
    {
      action = function()
        self:page_prev()
      end,
      mapping = mappings["page_prev"],
    },

    -- yank functions
    {
      action = function()
        self:store_current_wrapper("json", "yank")
      end,
      mapping = mappings["yank_current_json"],
    },
    {
      action = function()
        self:store_selection_wrapper("json", "yank")
      end,
      mapping = mappings["yank_selection_json"],
    },
    {
      action = function()
        self:store_all_wrapper("json", "yank")
      end,
      mapping = mappings["yank_all_json"],
    },
    {
      action = function()
        self:store_current_wrapper("csv", "yank")
      end,
      mapping = mappings["yank_current_csv"],
    },
    {
      action = function()
        self:store_selection_wrapper("csv", "yank")
      end,
      mapping = mappings["yank_selection_csv"],
    },
    {
      action = function()
        self:store_all_wrapper("csv", "yank")
      end,
      mapping = mappings["yank_all_csv"],
    },
  }
end

-- sets call's result to Result's buffer
---@param call call_details
function Result:set_call(call)
  self.page_index = 0
  self.page_ammount = 0
  self.current_call = call

  self.stop_progress()
end

function Result:page_current()
  self.page_index = self:display_result(self.page_index)
end

function Result:page_next()
  self.page_index = self:display_result(self.page_index + 1)
end

function Result:page_prev()
  self.page_index = self:display_result(self.page_index - 1)
end

-- wrapper for storing the current row
---@private
---@param format string
---@param output string
---@param arg any
function Result:store_current_wrapper(format, output, arg)
  local index = self:current_row_index()

  -- indexes in table start with 1, but in go they start with 0,
  -- to correct this, we subtract 1 from sindex and eindex.
  -- Since range select [:] in go is exclusive for the upper bound, we additionally add 1 to eindex
  index = index - 1
  if index <= 0 then
    index = 0
  end

  self.handler:call_store_result(
    self.current_call.id,
    format,
    output,
    { from = index, to = index + 1, extra_arg = arg }
  )
end

-- wrapper for storing the current visualy selected rows
---@private
---@param format string
---@param output string
---@param arg any
function Result:store_selection_wrapper(format, output, arg)
  local sindex, eindex = self:current_row_range()

  -- see above comment
  sindex = sindex - 1
  if sindex <= 0 then
    sindex = 0
  end

  self.handler:call_store_result(self.current_call.id, format, output, { from = sindex, to = eindex, extra_arg = arg })
end

-- wrapper for storing all rows
---@private
---@param format string
---@param output string
---@param arg any
function Result:store_all_wrapper(format, output, arg)
  self.handler:call_store_result(self.current_call.id, format, output, { extra_arg = arg })
end

---@private
---@return number # index of the current row
function Result:current_row_index()
  -- get position of the current line identifier
  local row = vim.fn.search([[^\s*[0-9]\+]], "bnc", 1)
  if row == 0 then
    error("couldn't retrieve current row number: row = 0")
  end

  -- get the line and extract the line number
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row - 1, row, true)[1] or ""

  local index = line:match("%d+")
  if not index then
    error("couldn't retrieve current row number")
  end
  return index
end

---@private
---@return number # number of the first row
---@return number # number of the last row
function Result:current_row_range()
  if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
    error("result cannot operate without a valid window")
  end
  -- get current selection
  local srow, _, erow, _ = utils.visual_selection()

  srow = srow + 1
  erow = erow + 1

  -- save cursor position
  local cursor_position = vim.fn.getcurpos(self.winid)

  -- reposition the cursor
  vim.fn.cursor(srow, 1)
  -- get position of the start line identifier
  local row = vim.fn.search([[^\s*[0-9]\+]], "bnc", 1)
  if row == 0 then
    error("couldn't retrieve start row number: row = 0")
  end

  -- get the selected line and extract the line number
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row - 1, row, true)[1] or ""

  local index_start = line:match("%d+")
  if not index_start then
    error("couldn't retrieve start row number")
  end

  -- reposition the cursor
  vim.fn.cursor(erow, 1)
  -- get position of the end line identifier
  row = vim.fn.search([[^\s*[0-9]\+]], "bnc", 1)
  if row == 0 then
    error("couldn't retrieve end row number: row = 0")
  end
  -- get the selected line and extract the line number
  line = vim.api.nvim_buf_get_lines(self.bufnr, row - 1, row, true)[1] or ""

  local index_end = tonumber(line:match("%d+"))
  if not index_end then
    error("couldn't retrieve end row number")
  end

  -- restore cursor position
  vim.fn.setpos(".", cursor_position)

  return index_start, index_end
end

---@param winid integer
function Result:show(winid)
  self.winid = winid

  -- configure window options
  ui_helper.configure_window_options(self.winid, {
    wrap = false,
    winfixheight = true,
    winfixwidth = true,
    number = false,
  })

  vim.api.nvim_win_set_buf(self.winid, self.bufnr)
end

return Result
