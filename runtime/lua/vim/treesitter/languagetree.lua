local query = require'vim.treesitter.query'
local language = require'vim.treesitter.language'

local LanguageTree = {}
LanguageTree.__index = LanguageTree

function LanguageTree.new(source, lang)
  language.require_language(lang)

  local self = setmetatable({
    _source=source,
    _lang=lang,
    _children = {},
    _ranges = {},
    _trees = {},
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

function LanguageTree:trees()
  return self._trees
end

function LanguageTree:lang()
  return self._lang
end

function LanguageTree:is_valid()
  return self._valid
end

function LanguageTree:parse()
  if self._valid then
    return self._trees
  end

  local parser = self._parser
  local changes = {}

  self._trees = {}

  -- If there are no ranges, set to an empty list
  -- so the included ranges in the parser ar cleared.
  if self._ranges and #self._ranges > 0 then
    for _, ranges in ipairs(self._ranges) do
      parser:set_included_ranges(ranges)

      local tree, tree_changes = parser:parse(nil, self._source)

      table.insert(self._trees, tree)
      vim.list_extend(changes, tree_changes)
    end
  else
    local tree, tree_changes = parser:parse(nil, self._source)

    table.insert(self._trees, tree)
    vim.list_extend(changes, tree_changes)
  end

  local injections_by_lang = self:_get_injections()
  local seen_langs = {}

  for lang, injection_ranges in pairs(injections_by_lang) do
    local child = self._children[lang]

    if not child then
      child = self:add_child(lang)
    end

    child:set_included_ranges(injection_ranges)

    local _, child_changes = child:parse()

    -- Propagate any child changes so they are included in the
    -- the change list for the callback.
    if child_changes then
      vim.list_extend(changes, child_changes)
    end

    seen_langs[lang] = true
  end

  for lang, _ in pairs(self._children) do
    if not seen_langs[lang] then
      self:remove_child(lang)
    end
  end

  self._valid = true

  self:_do_callback('changedtree', changes)
  return self._trees, changes
end

function LanguageTree:for_each_child(fn, include_self)
  if include_self then
    fn(self, self._lang)
  end

  for lang, child in pairs(self._children) do
    child:for_each_child(fn, true)
  end
end

function LanguageTree:for_each_tree(fn)
  for _, tree in ipairs(self._trees) do
    fn(tree, self)
  end

  for lang, child in pairs(self._children) do
    child:for_each_tree(fn)
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
  self._ranges = ranges
  self:invalidate()
end

function LanguageTree:included_ranges()
  return self._ranges
end

function LanguageTree:_get_injections()
  if not self._injection_query then return {} end

  local injections = {}

  for tree_index, tree in ipairs(self._trees) do
    local root_node = tree:root()
    local start_line, _, end_line, _ = root_node:range()

    for pattern, match in self._injection_query:iter_matches(root_node, self._source, start_line, end_line+1) do
      local lang = nil
      local injection_node = nil
      local combined = false

      -- You can specify the content and language together
      -- using a tag with the language, for example
      -- @javascript
      for id, node in pairs(match) do
        local name = self._injection_query.captures[id]
        -- TODO add a way to offset the content passed to the parser.
        -- Needed to shave off leading quotes and things of that nature.

        -- Lang should override any other language tag
        if name == "language" then
          lang = query.get_node_text(node, self._source)
        elseif name == "combined" then
          combined = true
        elseif name == "content" then
          injection_node = node
        else
          if lang == nil then
            lang = name
          end

          if not injection_node then
            injection_node = node
          end
        end
      end

      -- Each tree index should be isolated from the other nodes.
      if not injections[tree_index] then
        injections[tree_index] = {}
      end

      if not injections[tree_index][lang] then
        injections[tree_index][lang] = {}
      end

      -- Key by pattern so we can either combine each node to parse in the same
      -- context or treat each node independently.
      if not injections[tree_index][lang][pattern] then
        injections[tree_index][lang][pattern] = { combined = combined, nodes = {} }
      end

      table.insert(injections[tree_index][lang][pattern].nodes, injection_node)
    end
  end

  local result = {}

  -- Generate a map by lang of node lists.
  -- Each list is a set of ranges that should be parsed
  -- together.
  for index, lang_map in ipairs(injections) do
    for lang, patterns in pairs(lang_map) do
      if not result[lang] then
        result[lang] = {}
      end

      for _, entry in pairs(patterns) do
        if entry.combined then
          table.insert(result[lang], entry.nodes)
        else
          for _, node in ipairs(entry.nodes) do
            table.insert(result[lang], {node})
          end
        end
      end
    end
  end

  return result
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

  for _, tree in ipairs(self._trees) do
    tree:edit(start_byte,start_byte+old_byte,start_byte+new_byte,
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
