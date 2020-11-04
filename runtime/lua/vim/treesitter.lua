local a = vim.api
local query = require'vim.treesitter.query'
local language = require'vim.treesitter.language'
local LanguageTree = require'vim.treesitter.languagetree'

-- TODO(bfredl): currently we retain parsers for the lifetime of the buffer.
-- Consider use weak references to release parser if all plugins are done with
-- it.
local parsers = {}

local M = vim.tbl_extend("error", query, language)

setmetatable(M, {
  __index = function (t, k)
      if k == "TSHighlighter" then
        a.nvim_err_writeln("vim.TSHighlighter is deprecated, please use vim.treesitter.highlighter")
        t[k] = require'vim.treesitter.highlighter'
        return t[k]
      elseif k == "highlighter" then
        t[k] = require'vim.treesitter.highlighter'
        return t[k]
      end
   end
 })

--- Creates a new parser.
--
-- It is not recommended to use this, use vim.treesitter.get_parser() instead.
--
-- @param bufnr The buffer the parser will be tied to
-- @param lang The language of the parser.
function M._create_parser(bufnr, lang)
  language.require_language(lang)
  if bufnr == 0 then
    bufnr = a.nvim_get_current_buf()
  end

  vim.fn.bufload(bufnr)

  local self = LanguageTree.new(bufnr, lang)

  local function bytes_cb(_, ...)
    return self:_on_bytes(...)
  end
  local detach_cb = nil
  if id ~= nil then
    detach_cb = function()
      if parsers[bufnr] == self then
        parsers[bufnr] = nil
      end
    end
  end
  a.nvim_buf_attach(self.bufnr, false, {on_bytes=bytes_cb, on_detach=detach_cb})

  self:parse()

  return self
end

--- Gets the parser for this bufnr / ft combination.
--
-- If needed this will create the parser.
-- Unconditionnally attach the provided callback
--
-- @param bufnr The buffer the parser should be tied to
-- @param ft The filetype of this parser
-- @param buf_attach_cbs See Parser:register_cbs
--
-- @returns The parser
function M.get_parser(bufnr, lang, buf_attach_cbs)
  if bufnr == nil or bufnr == 0 then
    bufnr = a.nvim_get_current_buf()
  end
  if lang == nil then
    lang = a.nvim_buf_get_option(bufnr, "filetype")
  end

  if parsers[bufnr] == nil then
    parsers[bufnr] = M._create_parser(bufnr, lang)
  end

  parsers[bufnr]:register_cbs(buf_attach_cbs)

  return parsers[bufnr]
end

function M.get_string_parser(str, lang)
  vim.validate {
    str = { str, 'string' },
    lang = { lang, 'string' }
  }
  language.require_language(lang)

  return LanguageTree.new(str, lang)
end

return M
