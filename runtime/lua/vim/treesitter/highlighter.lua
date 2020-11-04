local a = vim.api

-- support reload for quick experimentation
local TSHighlighter = rawget(vim.treesitter, 'TSHighlighter') or {}
TSHighlighter.__index = TSHighlighter

TSHighlighter.active = TSHighlighter.active or {}

local ns = a.nvim_create_namespace("treesitter/highlighter")

-- These are conventions defined by nvim-treesitter, though it
-- needs to be user extensible also.
TSHighlighter.hl_map = {
    ["error"] = "Error",

-- Miscs
    ["comment"] = "Comment",
    ["punctuation.delimiter"] = "Delimiter",
    ["punctuation.bracket"] = "Delimiter",
    ["punctuation.special"] = "Delimiter",

-- Constants
    ["constant"] = "Constant",
    ["constant.builtin"] = "Special",
    ["constant.macro"] = "Define",
    ["string"] = "String",
    ["string.regex"] = "String",
    ["string.escape"] = "SpecialChar",
    ["character"] = "Character",
    ["number"] = "Number",
    ["boolean"] = "Boolean",
    ["float"] = "Float",

-- Functions
    ["function"] = "Function",
    ["function.special"] = "Function",
    ["function.builtin"] = "Special",
    ["function.macro"] = "Macro",
    ["parameter"] = "Identifier",
    ["method"] = "Function",
    ["field"] = "Identifier",
    ["property"] = "Identifier",
    ["constructor"] = "Special",

-- Keywords
    ["conditional"] = "Conditional",
    ["repeat"] = "Repeat",
    ["label"] = "Label",
    ["operator"] = "Operator",
    ["keyword"] = "Keyword",
    ["exception"] = "Exception",

    ["type"] = "Type",
    ["type.builtin"] = "Type",
    ["structure"] = "Structure",
    ["include"] = "Include",
}

function TSHighlighter.new(tree, query, opts)
  local self = setmetatable({}, TSHighlighter)

  opts = opts or {}

  self.tree = tree
  tree:register_cbs {
    on_changedtree = function(...) self:on_changedtree(...) end
  }

  self:set_query(query)
  self.bufnr = tree._source
  self.edit_count = 0
  self.redraw_count = 0
  self.line_count = {}

  a.nvim_buf_set_option(self.bufnr, "syntax", "")

  TSHighlighter.active[self.bufnr] = self

  -- Tricky: if syntax hasn't been enabled, we need to reload color scheme
  -- but use synload.vim rather than syntax.vim to not enable
  -- syntax FileType autocmds. Later on we should integrate with the
  -- `:syntax` and `set syntax=...` machinery properly.
  if vim.g.syntax_on ~= 1 then
    vim.api.nvim_command("runtime! syntax/synload.vim")
  end

  self.tree:parse()

  return self
end

local function is_highlight_name(capture_name)
  local firstc = string.sub(capture_name, 1, 1)
  return firstc ~= string.lower(firstc)
end

function TSHighlighter:destroy()
  if TSHighlighter.active[self.bufnr] then
    TSHighlighter.active[self.bufnr] = nil
  end
end

function TSHighlighter:get_hl_from_capture(capture)

  local name = self.query.captures[capture]

  if is_highlight_name(name) then
    -- From "Normal.left" only keep "Normal"
    return vim.split(name, '.', true)[1]
  else
    -- Default to false to avoid recomputing
    local hl = TSHighlighter.hl_map[name]
    return hl and a.nvim_get_hl_id_by_name(hl) or 0
  end
end

function TSHighlighter:on_changedtree(changes)
  for _, ch in ipairs(changes or {}) do
    a.nvim__buf_redraw_range(self.buf, ch[1], ch[3]+1)
  end
end

function TSHighlighter:set_query(query)
  if type(query) == "string" then
    query = vim.treesitter.parse_query(self.tree:lang(), query)
  end

  self.query = query

  self.hl_cache = setmetatable({}, {
    __index = function(table, capture)
      local hl = self:get_hl_from_capture(capture)
      rawset(table, capture, hl)

      return hl
    end
  })

  a.nvim__buf_redraw_range(self.tree.bufnr, 0, a.nvim_buf_line_count(self.tree.bufnr))
end

local function on_line_impl(self, buf, line)
  self.tree:for_each_child(function(tree)
    local tstree = tree.tree

    if not tstree then return end

    local root_node = tstree:root()
    local root_start_row, _, root_end_row, _ = root_node:range()

    -- Only worry about trees within the line range
    if root_start_row > line or root_end_row < line then return end

    if tree._highlight_iter == nil then
      tree._highlight_iter = self.query:iter_captures(root_node, self.bufnr, line, root_end_row + 1)
    end

    while line >= tree._highlight_next_row do
      local capture, node = tree._highlight_iter()

      if capture == nil then break end

      local start_row, start_col, end_row, end_col = node:range()
      local hl = self.hl_cache[capture]

      if hl and end_row >= line then
        a.nvim_buf_set_extmark(buf, ns, start_row, start_col,
                               { end_line = end_row, end_col = end_col,
                                 hl_group = hl,
                                 ephemeral = true
                                })
      end
      if start_row > line then
        tree._highlight_next_row = start_row
      end
    end
  end, true)
end

function TSHighlighter._on_line(_, _win, buf, line, highlighter)
  local self = TSHighlighter.active[buf]
  if not self then return end

  on_line_impl(self, buf, line)
end

function TSHighlighter._on_buf(_, buf)
  local self = TSHighlighter.active[buf]
  if self then
    self:parse()
  end
end

function TSHighlighter._on_win(_, _win, buf, _topline, botline)
  local self = TSHighlighter.active[buf]
  if not self then
    return false
  end

  self.tree:for_each_child(function(tree)
    tree._highlight_iter = nil
    tree._highlight_next_row = 0
  end, true)

  self.redraw_count = self.redraw_count + 1
  return true
end

a.nvim_set_decoration_provider(ns, {
  on_buf = TSHighlighter._on_buf;
  on_win = TSHighlighter._on_win;
  on_line = TSHighlighter._on_line;
})

return TSHighlighter
