-- TESTS/tasks_form_toggle_spec.lua -- ticking in the :Tasks new form: the bullet toggle of cascade.nvim when it is there
-- (a soft dependency), the form's own toggle otherwise, on the choice lists and on the scaffold lines.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local form = require("tasks_nvim.form")
  local ui = require("tasks_nvim.ui.form")

  ---A scratch buffer in the current window with the form text.
  ---@param lines string[]
  ---@return integer buf
  local function open(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.b[buf].tasks_form_lang = "en"
    return buf
  end

  local function line_of(buf, text)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l == text then
        return i
      end
    end
    return nil
  end

  ---Put the cursor on the line `text` and toggle.
  local function toggle(buf, text)
    local at = line_of(buf, text)
    ok(at, "no line '" .. text .. "'")
    vim.api.nvim_win_set_cursor(0, { at, 0 })
    return ui.toggle_here(buf)
  end

  local function fresh(ticks)
    return open(form.template({ lang = "en", ticks = ticks }))
  end

  -- ── without cascade.nvim: the form's own toggle ────────────────────────
  package.loaded["cascade"], package.preload["cascade"] = nil, nil
  local buf = fresh({ kind = "feature", category = { "bindings" } })
  ok(toggle(buf, "- [x] Spec added"), "a scaffold line toggles")
  ok(line_of(buf, "- [ ] Spec added"), "unticked")
  -- the choice moves on: the unticked line stays unticked while the block is rewritten
  ok(toggle(buf, "- [ ] docs"), "a category ticks")
  ok(
    line_of(buf, "- [ ] Spec added"),
    "an unticked scaffold line stays unticked after a tick elsewhere"
  )
  ok(line_of(buf, "- [x] Mapping only through the config, no default"))
  -- a one-choice list keeps one tick
  ok(toggle(buf, "- [ ] bug"))
  ok(line_of(buf, "- [x] bug") and line_of(buf, "- [ ] feature"))
  ok(line_of(buf, "- [x] Steps to reproduce described"), "the lines follow the kind")
  ok(line_of(buf, "## severity (one)"), "and severity fits now")
  -- a line that is no choice bullet is not handled (the key keeps its normal meaning)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  eq(ui.toggle_here(buf), false)

  -- ── with cascade.nvim: its toggle does the flip ────────────────────────
  local calls = 0
  package.preload["cascade"] = function()
    return {
      toggle_checkbox = function()
        calls = calls + 1
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local l = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
        vim.api.nvim_buf_set_lines(0, row - 1, row, false, { (l:gsub("%[ %]", "[x]", 1)) })
      end,
    }
  end
  package.loaded["cascade"] = nil
  local buf2 = fresh({ kind = "feature" })
  ok(toggle(buf2, "- [ ] bug"))
  eq(calls, 1, "ticking goes through cascade")
  ok(
    line_of(buf2, "- [x] bug") and line_of(buf2, "- [ ] feature"),
    "a one-choice list still keeps one tick"
  )
  ok(
    line_of(buf2, "- [x] Steps to reproduce described"),
    "the scaffold follows after cascade's flip too"
  )
  -- the way back is the form's own (cascade may cycle through more states than ticked and unticked)
  ok(toggle(buf2, "- [x] Steps to reproduce described"))
  eq(calls, 1, "unticking does not ask cascade")
  ok(line_of(buf2, "- [ ] Steps to reproduce described"))

  -- ── cascade that fails or does nothing: the form's own toggle takes over
  package.preload["cascade"] = function()
    return {
      toggle_checkbox = function()
        error("boom")
      end,
    }
  end
  package.loaded["cascade"] = nil
  local buf3 = fresh({})
  ok(toggle(buf3, "- [ ] docs"))
  ok(line_of(buf3, "- [x] docs"), "ticked all the same")

  package.preload["cascade"] = function()
    return { toggle_checkbox = function() end }
  end
  package.loaded["cascade"] = nil
  ok(toggle(buf3, "- [ ] ux"))
  ok(line_of(buf3, "- [x] ux"), "a cascade that does nothing is no reason to stay unticked")

  package.loaded["cascade"], package.preload["cascade"] = nil, nil
end
