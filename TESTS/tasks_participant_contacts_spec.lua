-- TESTS/tasks_participant_contacts_spec.lua -- a participant of a meeting resolves to a contact when it is read: by
-- mail address (case does not matter), by a name that links to the contact (`[Rick](<area>/rick)`), never when no
-- contact has it (the line stays text) and never guessed when several contacts hold the address (the candidates are
-- named). The documents `tasks.meeting` (`contact`, `contact_candidates`) and `tasks.contact` (`history`), the `check`
-- hint `meeting-participant-ambiguous` and the rule that no file holds the link twice.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local check = require("tasks_nvim.check")
  local meetings = require("tasks_nvim.meetings")

  local root = F.vault(H)
  meetings.reset_cache()

  local function call(method, params)
    local text = api.call(method, { params = params or {} }, { root = root, today = F.TODAY })
    return vim.json.decode(text), text
  end
  local function contact(slug, name, emails)
    H.write(
      root .. "/lib.nvim/CONTACTS/" .. slug .. ".md",
      ("---\nname: %s\nemails: [%s]\n---\n\nA person.\n"):format(name, emails)
    )
  end
  local function meeting(slug, date, people)
    H.write(
      root .. "/lib.nvim/MEETINGS/" .. slug .. ".md",
      ("---\ntitle: %s\nstatus: planned\ndate: %s\n---\n\nNote.\n\n## Teilnehmer\n%s\n"):format(
        slug,
        date,
        table.concat(people, "\n")
      )
    )
  end

  contact("rick", "Rick Beispiel", "rick@example.org, r.beispiel@example.org")
  contact("anna-muster", "Anna Muster", "anna@example.org")
  -- two contacts with the same address
  contact("twin-a", "Twin A", "twin@example.org")
  contact("twin-b", "Twin B", "twin@example.org")

  meeting("sync", "2026-10-10", {
    "- [x] Rick <RICK@Example.org> (Organisator)", -- by mail, case does not matter
    "- [ ] [Anna](lib.nvim/anna-muster) (Gast)", -- by link, no mail
    "- [ ] Fremd <fremd@example.org>", -- no contact: stays text
    "- [ ] Zwilling <twin@example.org>", -- two contacts: ambiguous
    "- [ ] [Zwilling B](lib.nvim/twin-b) <twin@example.org>", -- the link settles it
    "- [ ] [Geist](lib.nvim/nobody)", -- a link to nothing
    "- Plain Name",
  })
  meeting("review", "2026-11-02", { "- Anna <anna@example.org>" })
  meeting("old", "2026-09-01", { "- [Rick](lib.nvim/rick)" })

  local doc = call("meeting", { id = "lib.nvim/sync" })
  local p = doc.participants
  eq(#p, 7)
  eq(p[1].contact, "lib.nvim/rick", "resolved by mail, case folded")
  eq(p[1].name, "Rick")
  eq(p[1].role, "Organisator")
  eq(p[2].contact, "lib.nvim/anna-muster", "resolved by link")
  eq(p[2].name, "Anna", "the link text is the name")
  eq(p[2].role, "Gast", "a link before the role is no role")
  eq(p[2].email, nil)
  eq(p[3].contact, nil, "an address no contact has stays text")
  eq(p[3].contact_candidates, nil)
  eq(p[3].email, "fremd@example.org")
  eq(p[4].contact, nil, "an address two contacts hold is never guessed")
  eq(p[4].contact_candidates, { "lib.nvim/twin-a", "lib.nvim/twin-b" })
  eq(p[5].contact, "lib.nvim/twin-b", "a link wins over an ambiguous address")
  eq(p[5].contact_candidates, nil)
  eq(p[6].contact, nil, "a link to a contact that does not exist resolves to nothing")
  eq(p[7].contact, nil)

  -- the counts of the entry stay as they were
  local listed = call("meetings", { since = "2026-09-01", ["until"] = "2026-12-31" })
  eq(listed.items[2].participants, { total = 7, present = 1 })

  -- the history of a contact: its meetings, the latest first, nothing written into any file
  local rick = call("contact", { id = "lib.nvim/rick" })
  eq(
    vim.tbl_map(function(h)
      return h.id
    end, rick.history),
    { "lib.nvim/sync", "lib.nvim/old" }
  )
  eq(rick.history[1].participant, 1)
  eq(rick.history[1].role, "Organisator")
  eq(rick.history[1].present, true)
  eq(rick.history[1].title, "sync")
  eq(rick.history[1].date, "2026-10-10")
  eq(rick.history[2].participant, 1)
  local anna = call("contact", { id = "lib.nvim/anna-muster" })
  eq(
    vim.tbl_map(function(h)
      return h.id
    end, anna.history),
    { "lib.nvim/review", "lib.nvim/sync" }
  )
  -- an ambiguous address is in no one's history
  local twin_a = call("contact", { id = "lib.nvim/twin-a" })
  eq(twin_a.history, {})
  eq(
    vim.tbl_map(function(h)
      return h.id
    end, call("contact", { id = "lib.nvim/twin-b" }).history),
    { "lib.nvim/sync" }
  )
  eq(rick.history_truncated, nil)

  -- the revision of a contact follows its history and the contacts that share an address
  local rev = rick.rev
  meeting("review", "2026-11-02", { "- Anna <anna@example.org>", "- Rick <rick@example.org>" })
  meetings.reset_cache()
  ok(call("contact", { id = "lib.nvim/rick" }).rev ~= rev, "a new meeting changes the revision")
  local twin_rev = twin_a.rev
  contact("twin-b", "Twin B", "other@example.org")
  meetings.reset_cache()
  eq(
    call("meeting", { id = "lib.nvim/sync" }).participants[4].contact,
    "lib.nvim/twin-a",
    "the twin left: the address is one contact's"
  )
  ok(
    call("contact", { id = "lib.nvim/twin-a" }).rev ~= twin_rev,
    "the twin left: the revision moves"
  )

  -- the contract is additive: the capability, and no mail address in a problem
  ok(vim.tbl_contains(call("hello").capabilities, "participant_contacts"))
  local _, text = call("contact", { id = "lib.nvim/rick" })
  ok(not text:find("RICK@", 1, true))

  -- check: the ambiguous address is a hint; a link to a contact is no dead file link, a link to nothing is
  contact("twin-b", "Twin B", "twin@example.org")
  meetings.reset_cache()
  local res = check.run({ root = root, area = "lib.nvim", today = F.TODAY, ui_words = false })
  local function codes(list, id)
    local out = {}
    for _, f in ipairs(list) do
      if f.id == id then
        out[#out + 1] = f.code
      end
    end
    table.sort(out)
    return out
  end
  eq(codes(res.hints, "lib.nvim/sync"), { "meeting-participant-ambiguous" })
  eq(codes(res.findings, "lib.nvim/sync"), { "meeting-link-missing" }, "only the link to nobody")
  eq(codes(res.findings, "lib.nvim/old"), {}, "a link to a contact is no dead link")
  eq(codes(res.hints, "lib.nvim/old"), {})
  for _, f in ipairs(res.hints) do
    ok(not (f.message or ""):find("@", 1, true), "a hint names no mail address: " .. f.message)
  end
end
