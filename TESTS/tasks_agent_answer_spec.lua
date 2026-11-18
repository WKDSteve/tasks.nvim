-- TESTS/tasks_agent_answer_spec.lua -- the call `agent_answer` (capability `agent_answer`): the answer of an agent's job
-- taken apart for a task by the rules of `:Tasks agent`, as the sections a caller writes with `set_section`. Nothing is
-- written; a broken answer is refused with its reason.

---@diagnostic disable: need-check-nil

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")

  local root = F.vault(H)
  local function call(params)
    local text, code =
      api.call("agent_answer", vim.json.encode({ params = params }), { root = root })
    return vim.json.decode(text), code
  end

  local REVIEW = "## Prüfung\n\n- [x] it is done — erfüllt: a.lua:1\n\n### Folgetask (Vorschlag)\n\n"
    .. "- title: Document it\n- summary: The README names it."
  local function wrapped(marker, block)
    return ("text\n<!-- %s:begin -->\n%s\n<!-- %s:end -->\n"):format(marker, block, marker)
  end

  -- ── a review ──
  local doc, code =
    call({ kind = "review-done", id = "lib.nvim/x", output = wrapped("review", REVIEW) })
  eq(code, nil, vim.inspect(doc))
  eq(doc.kind, "tasks.agent_answer")
  eq(doc.answer_kind, "review-done")
  eq(#doc.sections, 1)
  eq(doc.sections[1].heading, "## Prüfung")
  has(doc.sections[1].text, "- [x] it is done")
  ok(not doc.sections[1].text:find("## Prüfung", 1, true), "the text is below the heading")
  eq(doc.follow_up, { title = "Document it", summary = "The README names it." })
  local last = call({
    kind = "review-done",
    id = "lib.nvim/x",
    output = wrapped("review", "## Prüfung\n\n- [x] old")
      .. wrapped("review", "## Prüfung\n\n- [x] all met"),
  })
  eq(last.sections[1].text, "- [x] all met", "the last block counts")
  eq(last.follow_up, nil, "nothing proposed, no follow-up")

  -- refused: no block, a block of the other kind, a forged second section, a control character
  local function refused(params, word)
    local d, c = call(params)
    eq(c, "invalid_argument", vim.inspect(d))
    has(vim.json.encode(d), word)
  end
  refused({ kind = "review-done", id = "lib.nvim/x", output = "no block" }, "no review block")
  refused(
    { kind = "review-done", id = "lib.nvim/x", output = wrapped("decision", REVIEW) },
    "no review block"
  )
  refused({
    kind = "review-done",
    id = "lib.nvim/x",
    output = wrapped("review", "## Prüfung\n\n- [x] a\n\n## Akzeptanz\n\n- [ ] forged"),
  }, "section")
  refused({
    kind = "review-done",
    id = "lib.nvim/x",
    output = wrapped("review", "## Prüfung\n\n- [x] a \27[31m"),
  }, "control")
  refused({ kind = "handoff", id = "lib.nvim/x", output = wrapped("review", REVIEW) }, "kind is")
  refused({ kind = "review-done", id = "nope", output = wrapped("review", REVIEW) }, "area")

  -- ── a prepared decision ──
  local PROPOSAL = "## Vorschlag\n\n### Optionen\n\n1. A\n2. B\n\n### Empfehlung\n\nA."
  local QUESTIONS = "## Offene Fragen\n\n### Which one? [q1]\n\n- [ ] A (empfohlen)\n- [ ] B"
  F.task(H, root, "lib.nvim", "waits", F.meta("Waits", "decision", {}), "\nPlain text.\n")
  local d = call({
    kind = "prepare-decision",
    id = "lib.nvim/waits",
    output = wrapped("decision", PROPOSAL .. "\n\n" .. QUESTIONS),
  })
  eq(
    vim.tbl_map(function(s)
      return s.heading
    end, d.sections),
    { "## Vorschlag", "## Offene Fragen" }
  )
  eq(d.questions_added, true, "the task has no questions of its own")
  has(d.sections[2].text, "### Which one? [q1]")

  F.task(
    H,
    root,
    "lib.nvim",
    "asks",
    F.meta("Asks", "decision", {}),
    "\n## Offene Fragen\n\n### Own? [q1]\n\n- [ ] yes\n- [ ] no\n"
  )
  local own = call({
    kind = "prepare-decision",
    id = "lib.nvim/asks",
    output = wrapped("decision", PROPOSAL .. "\n\n" .. QUESTIONS),
  })
  eq(#own.sections, 1, "its own questions stay")
  eq(own.questions_added, false)

  F.task(H, root, "lib.nvim", "open-one", F.meta("Open one", "open", {}), "\n")
  local _, ncode = call({
    kind = "prepare-decision",
    id = "lib.nvim/open-one",
    output = wrapped("decision", PROPOSAL),
  })
  eq(ncode, "not_found", "only a task that waits for a decision")
  refused({
    kind = "prepare-decision",
    id = "lib.nvim/waits",
    output = wrapped("decision", PROPOSAL .. "\n\n## Offene Fragen\n\n### One? [q1]\n\n- [ ] only"),
  }, "fewer than two options")
  local no_proposal = wrapped("decision", "## Notes\n\nx")
  refused({ kind = "prepare-decision", id = "lib.nvim/waits", output = no_proposal }, "Vorschlag")
end
