local layout = require("dbee.layout")

local M = {}
local m = {}

---@class UiConfig
---@field window_open_order table example: { "result", "editor", "drawer" } - in which order are the windows open
---@field pre_open_hook fun() execute this before opening ui
---@field post_open_hook fun() execute this after opening ui
---@field pre_close_hook fun() execute this before closing ui
---@field post_close_hook fun() execute this after closing ui

-- configuration object
---@class Config
---@field connections { name: string, type: string, url: string }[] list of configured database connections
---@field lazy boolean lazy load the plugin or not?
---@field drawer drawer_config
---@field editor editor_config
---@field result handler_config
---@field ui UiConfig

-- default configuration
---@type Config
M.default = {
  connections = {},
  lazy = false,
  drawer = {
    window_command = "to 40vsplit",
    disable_icons = false,
    mappings = {
      refresh = "r",
      action_1 = "<CR>",
      action_2 = "da",
      action_3 = "dd",
      collapse = "c",
      expand = "e",
      toggle = "o",
    },
    icons = {
      history = {
        icon = "",
        highlight = "Constant",
      },
      scratch = {
        icon = "",
        highlight = "Character",
      },
      database = {
        icon = "",
        highlight = "SpecialChar",
      },
      table = {
        icon = "",
        highlight = "Conditional",
      },

      -- if there is no type
      -- use this for normal nodes...
      none = {
        icon = " ",
      },
      -- ...and use this for nodes with children
      none_dir = {
        icon = "",
        highlight = "NonText",
      },
    },
  },
  result = {
    window_command = "bo 15split",
  },
  editor = {
    window_command = function()
      vim.cmd("new")
      vim.cmd("only")
      m.tmp_buf = vim.api.nvim_get_current_buf()
      return vim.api.nvim_get_current_win()
    end,
    mappings = {
      run_selection = "BB",
      run_file = "BB",
    },
  },
  ui = {
    window_open_order = { "editor", "result", "drawer" },
    pre_open_hook = function()
      -- save layout before opening ui
      m.egg = layout.save()
    end,
    post_open_hook = function()
      -- delete temporary editor buffer
      vim.cmd("bd " .. m.tmp_buf)
    end,
    pre_close_hook = function() end,
    post_close_hook = function()
      layout.restore(m.egg)
      m.egg = nil
    end,
  },
}

return M
