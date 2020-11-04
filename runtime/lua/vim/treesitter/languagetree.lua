local query = require'vim.treesitter.query'
local language = require'vim.treesitter.language'

local LanguageTree = {}
LanguageTree.__index = LanguageTree

function LanguageTree.new(source, lang, opts)
  opts = opts or {}
  language.require_language(lang)

  local self = setmetatable({
    _source=source,
    _lang=lang,
    _children = {},
    _tree = nil,
    _injection_query = query.get_query(lang, "injections"),
    _valid = false,
    _parser = vim._create_ts_parser(lang),
    _callbacks = {
      changedtree = {},
      bytes = {},
      child_added = {},
      child_removed = {}
    },
  }, LanguageTree)


  return self
end

-- Invalidates this parser and all it's children
function LanguageTree:invalidate()
  self._valid = false

  for _, child in ipairs(self._children) do
    child:invalidate()
  end
end

function LanguageTree:lang()
  return self._lang
end

function LanguageTree:is_valid()
  return self._valid
end

function LanguageTree:parse()
  if self._valid then
    return self._tree
  end

  local parser = self._parser

  local tree, changes = parser:parse(self._tree, self._source)

  local injections_by_lang = self:_get_injections()
  local seen_langs = {}

  for lang, injections in pairs(injections_by_lang) do
    local child = self._children[lang]
    if not child then
      child = self:add_child(lang)
    end
    seen_langs[lang] = true
  end

  for lang, _ in pairs(self._children) do
    if not seen_langs[lang] then
      self:remove_child(lang)
    end
  end

  self._tree = tree
  self._valid = true

  self:_do_callback('changedtree', changes)
  return self._tree, changes
end

function LanguageTree:for_each_child(fn, include_self)
  if include_self then
    fn(self, self._lang)
  end

  for lang, child in pairs(self._children) do
    fn(child, lang)

    child:for_each_child(fn)
  end
end

function LanguageTree:add_child(lang)
  if self._children[lang] then
    self:remove_child(lang)
  end

  self._children[lang] = LanguageTree.new(self._source, lang, {})

  self:invalidate()
  self:_do_callback('child_added', self._children[lang])

  return self._children[lang]
end

function LanguageTree:remove_child(lang)
  local child = self._children[lang]

  if child then
    self._children[lang] = nil
    child:destroy()
    self:invalidate()
    self:_do_callback('child_removed', child)
  end
end

function LanguageTree:destroy()
  -- Cleanup here
  for _, child in ipairs(self._children) do
    child:destroy()
  end
end

function LanguageTree:set_included_ranges(ranges)
  self._parser:set_included_ranges(ranges)
  self:invalidate()
end

function LanguageTree:included_ranges()
  return self._parser:included_ranges()
end

function LanguageTree:_get_injections()
  if not self._injection_query then return {} end

  local injections = {}

  for pattern, match in self._injection_query:iter_matches(self._tree, self._source) do
    local lang = nil
    local injection_node = nil

    for id, node in pairs(match) do
      local name = query.captures[id]

      -- Lang should override any other language tag
      if name == "lang" then
        lang = query.get_node_text(node, self._source)
      else
        if lang == nil then
          lang = name
        end

        injection_node = node
      end
    end

    if not injections[lang] then
      injections[lang] = {}
    end

    table.insert(injections[lang], injection_node)
  end

  return injections
end

function LanguageTree:_do_callback(cb_name, ...)
  for _, cb in ipairs(self._callbacks[cb_name]) do
    cb(...)
  end
end

function LanguageTree:_on_bytes(bufnr, changed_tick,
                          start_row, start_col, start_byte,
                          old_row, old_col, old_byte,
                          new_row, new_col, new_byte)
  self:invalidate()

  if self._tree then
    self._tree:edit(start_byte,start_byte+old_byte,start_byte+new_byte,
      start_row, start_col,
      start_row+old_row, old_end_col,
      start_row+new_row, new_end_col)
  end

  self:_do_callback('bytes', bufnr, changed_tick,
      start_row, start_col, start_byte,
      old_row, old_col, old_byte,
      new_row, new_col, new_byte)
end

--- Registers callbacks for the parser
-- @param cbs An `nvim_buf_attach`-like table argument with the following keys :
--  `on_bytes` : see `nvim_buf_attach`, but this will be called _after_ the parsers callback.
--  `on_changedtree` : a callback that will be called everytime the tree has syntactical changes.
--      it will only be passed one argument, that is a table of the ranges (as node ranges) that
--      changed.
function LanguageTree:register_cbs(cbs)
  if not cbs then return end

  if cbs.on_changedtree then
    table.insert(self._callbacks.changedtree, cbs.on_changedtree)
  end

  if cbs.on_bytes then
    table.insert(self._callbacks.bytes, cbs.on_bytes)
  end

  if cbs.on_child_added then
    table.insert(self._callbacks.child_added, cbs.on_child_added)
  end

  if cbs.on_child_removed then
    table.insert(self._callbacks.child_removed, cbs.on_child_removed)
  end
end

return LanguageTree
