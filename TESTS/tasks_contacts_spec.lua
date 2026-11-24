-- TESTS/tasks_contacts_spec.lua -- the contacts of the vault (`<area>/CONTACTS/<slug>.md`, `tasks_nvim.contacts`): the
-- parser and the notes section, the `check` codes `contact-*`, the write door (`contact_new`, `contact_set`,
-- `contact_delete` with their inverses and `if_match`), the documents `tasks.contacts` and `tasks.contact`, the id
-- namespace (a task, a meeting and a `move_area` meet a contact), and the rule that no mail address and no phone
-- number is named in an error text, a log line or a note of the contract.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local api = require("tasks_nvim.api")
  local check = require("tasks_nvim.check")
  local contacts = require("tasks_nvim.contacts")
  local ops_mod = require("tasks_nvim.ops")

  local root = F.vault(H)
  F.task(H, root, "lib.nvim", "prep", F.meta("Prep", "open"))
  F.task(H, root, "lib.nvim", "taken", F.meta("Taken", "open"))
  require("tasks_nvim.index").write_area("lib.nvim", { root = root })

  local MAIL = "rick@example.org"
  local PHONE = "+43 1 2345678"

  local function contact_file(area, slug, text)
    local path = root .. "/" .. area .. "/CONTACTS/" .. slug .. ".md"
    H.write(path, text)
    return path
  end
  local function run(list, dry)
    local doc, err = ops_mod.run(
      { ops = list, dry_run = dry or nil },
      { root = root, today = F.TODAY }
    )
    assert(doc, tostring(err))
    eq(doc.kind, "tasks.result", vim.inspect(doc))
    return doc
  end
  local function one(op, dry)
    return run({ op }, dry).results[1]
  end
  local function read(id)
    return assert(contacts.find(id, { root = root }))
  end
  local function call(method, params)
    local text = api.call(method, { params = params or {} }, { root = root, today = F.TODAY })
    return vim.json.decode(text), text
  end

  -- ── the parser ──
  local text = table.concat({
    "---",
    'name: "Rick Beispiel"',
    'org: "Beispiel GmbH"',
    'role: "Support, T2"',
    "emails: [" .. MAIL .. "]",
    'phones: ["' .. PHONE .. '"]',
    "tz: Europe/Vienna",
    "tags: [t2, kunde]",
    "created: 2026-10-01",
    "---",
    "",
    "Short note about Rick.",
    "",
    "## Notizen",
    "",
    "Prefers mail.",
    "",
    "## Other",
    "",
    "not a note",
    "",
  }, "\n")
  local parsed = contacts.parse(text, { path = "rick.md", area = "lib.nvim", slug = "rick" })
  ok(parsed.valid, vim.inspect(parsed.errors))
  eq(parsed.id, "lib.nvim/rick")
  eq(parsed.name, "Rick Beispiel")
  eq(parsed.org, "Beispiel GmbH")
  eq(parsed.role, "Support, T2")
  eq(parsed.emails, { MAIL })
  eq(parsed.phones, { PHONE })
  eq(parsed.tz, "Europe/Vienna")
  eq(parsed.tags, { "t2", "kunde" })
  eq(parsed.summary, "Short note about Rick.")
  eq(parsed.notes, "Prefers mail.", "the notes section, up to the next heading")
  eq(contacts.notes_of("## Notes\n\nEnglish note\n"), "English note")

  -- the forms of a mail address and of a number
  for _, good in ipairs({ MAIL, "a.b+c@sub.example.co" }) do
    ok(contacts.is_email(good), good)
  end
  for _, bad in ipairs({
    "rick",
    "rick@",
    "@example.org",
    "a@b",
    "a b@example.org",
    "a@@example.org",
  }) do
    ok(not contacts.is_email(bad), bad)
  end
  for _, good in ipairs({ PHONE, "0664 1234567", "(01) 234-5678" }) do
    ok(contacts.is_phone(good), good)
  end
  for _, bad in ipairs({ "12345", "call me", "+43+43 1234567", "1234567890123456789" }) do
    ok(not contacts.is_phone(bad), bad)
  end

  -- ── scrub: the one place a mail address and a phone number leave a text ──
  local scrubbed = contacts.scrub("write to " .. MAIL .. " or call " .. PHONE .. " (room 12)")
  ok(not scrubbed:find("rick", 1, true), scrubbed)
  ok(not scrubbed:find("2345678", 1, true), scrubbed)
  has(scrubbed, "room 12", "a short number is no phone number")
  -- a version tag of all digits and a calendar day are no numbers of a person: a conflict names them
  eq(
    contacts.scrub("is sha256:1234567890123456, made on sha256:0000000000000000"),
    "is sha256:1234567890123456, made on sha256:0000000000000000"
  )
  eq(contacts.scrub("created 2026-10-20, call " .. PHONE), "created 2026-10-20, call <redacted>")

  -- ── check: one code each, and no message names the mail or the number ──
  contact_file("lib.nvim", "good", text)
  contact_file("lib.nvim", "nameless", "---\nemails: [a@example.org]\n---\n\ntext\n")
  contact_file(
    "lib.nvim",
    "badmail",
    "---\nname: Bad Mail\nemails: [" .. "oops-" .. MAIL:gsub("@", "(at)") .. "@@x]\n---\n"
  )
  contact_file("lib.nvim", "badphone", "---\nname: Bad Phone\nphones: [call-" .. "1234]\n---\n")
  contact_file("lib.nvim", "badtz", "---\nname: Bad Zone\ntz: Vienna\n---\n")
  contact_file("lib.nvim", "taken", "---\nname: Same Id As A Task\n---\n")
  -- a message that quotes a value: a mail address written in the wrong field, a file named after a number
  contact_file("lib.nvim", "leak", "---\nname: Leak\ntz: " .. MAIL .. "\n---\n")
  contact_file("lib.nvim", "Rick " .. PHONE, "---\nname: Named By Number\n---\n")
  contact_file("lib.nvim", "no-frontmatter", "Rick, " .. MAIL .. ", " .. PHONE .. "\n")
  local res = check.run({ root = root, area = "lib.nvim", today = F.TODAY, ui_words = false })
  local function codes(id)
    local out = {}
    for _, f in ipairs(res.findings) do
      if f.id == id then
        out[#out + 1] = f.code
      end
    end
    table.sort(out)
    return out
  end
  eq(codes("lib.nvim/good"), {}, "a good contact says nothing")
  eq(codes("lib.nvim/nameless"), { "contact-name-missing" })
  eq(codes("lib.nvim/badmail"), { "contact-bad-email" })
  eq(codes("lib.nvim/badphone"), { "contact-bad-phone" })
  eq(codes("lib.nvim/badtz"), { "contact-bad-tz" })
  eq(codes("lib.nvim/taken"), { "contact-id-taken" }, "a task of the same slug")
  eq(codes("lib.nvim/leak"), { "contact-bad-tz" })
  eq(codes("lib.nvim/no-frontmatter"), { "frontmatter-missing" })
  local seen_number_file = false
  for _, list in ipairs({ res.findings, res.hints }) do
    for _, f in ipairs(list) do
      if f.id and f.id:find("^lib.nvim/") then
        ok(not f.message:find("rick@", 1, true), "a mail in: " .. f.message)
        ok(not f.message:find("2345678", 1, true), "a number in: " .. f.message)
        if f.id:find("^lib.nvim/Rick ") then
          seen_number_file = true
          eq(f.code, "slug")
        end
      end
    end
  end
  ok(seen_number_file, "the file named after a number is reported, its message without the number")

  -- the document: the same words, the same rule
  local list_doc, list_text = call("contacts", { area = "lib.nvim" })
  eq(list_doc.kind, "tasks.contacts")
  local by_id = {}
  for _, c in ipairs(list_doc.items) do
    by_id[c.id] = c
  end
  eq(by_id["lib.nvim/good"].emails, { MAIL }, "a valid contact carries its mail: it is data")
  eq(by_id["lib.nvim/good"].valid, true)
  eq(by_id["lib.nvim/badtz"].valid, false)
  eq(by_id["lib.nvim/badtz"].problems[1].code, "contact-bad-tz")
  eq(by_id["lib.nvim/leak"].problems[1].code, "contact-bad-tz")
  ok(#by_id["lib.nvim/no-frontmatter"].problems > 0)
  for _, c in ipairs(list_doc.items) do
    for _, p in ipairs(c.problems) do
      ok(not p.msg:find("rick@", 1, true), "a mail in a problem: " .. p.msg)
      ok(not p.msg:find("2345678", 1, true), "a number in a problem: " .. p.msg)
    end
  end
  ok(list_text:find("Rick Beispiel", 1, true))
  eq(by_id["lib.nvim/good"].file, "lib.nvim/CONTACTS/good.md", "no path of this machine")

  -- filters, order and paging
  eq(call("contacts", { tag = "t2" }).total, 1)
  eq(call("contacts", { org = "beispiel gmbh" }).total, 1, "the organisation: case does not matter")
  eq(call("contacts", { area = "cascade.nvim" }).total, 0)
  local page = call("contacts", { limit = 2 })
  eq(#page.items, 2)
  eq(page.next_offset, 2)
  local names = {}
  for _, c in ipairs(call("contacts", {}).items) do
    names[#names + 1] = c.name:lower()
  end
  local sorted = vim.deepcopy(names)
  table.sort(sorted)
  eq(names, sorted, "by name")
  eq(call("contacts", { area = "nowhere" }).code, "not_found")

  local one_doc = call("contact", { id = "lib.nvim/good" })
  eq(one_doc.kind, "tasks.contact")
  eq(one_doc.notes, "Prefers mail.")
  eq(one_doc.contact.name, "Rick Beispiel")
  eq(call("contact", { id = "lib.nvim/missing" }).code, "not_found")
  local hello = call("hello")
  ok(vim.tbl_contains(hello.capabilities, "contacts"))

  -- clean the fixtures of the check: the rest of the spec writes its own
  for _, slug in ipairs({
    "nameless",
    "badmail",
    "badphone",
    "badtz",
    "taken",
    "no-frontmatter",
    "Rick " .. PHONE,
  }) do
    os.remove(root .. "/lib.nvim/CONTACTS/" .. slug .. ".md")
  end

  -- ── contact_new ──
  local dry = one({
    op = "contact_new",
    area = "lib.nvim",
    name = "Anna Muster",
    fields = {
      org = "Muster AG",
      emails = { "anna@example.org" },
      phones = { PHONE },
      tags = { "kunde" },
    },
  }, true)
  ok(dry.ok, vim.inspect(dry))
  eq(dry.outcome, "would_create")
  eq(dry.id, "lib.nvim/anna-muster")
  ok(not H.exists(root .. "/lib.nvim/CONTACTS/anna-muster.md"), "a dry run writes nothing")
  local made = one({
    op = "contact_new",
    area = "lib.nvim",
    name = "Anna Muster",
    fields = {
      org = "Muster AG",
      emails = { "anna@example.org" },
      phones = { PHONE },
      tags = { "kunde" },
    },
  })
  ok(made.ok, vim.inspect(made))
  eq(made.outcome, "created")
  eq(made.inverse.op, "contact_delete")
  eq(made.inverse.if_match, made.etag_after)
  local anna = read("lib.nvim/anna-muster")
  ok(anna.valid, vim.inspect(anna.errors))
  eq(anna.emails, { "anna@example.org" })
  eq(anna.phones, { PHONE })
  eq(anna.created, F.TODAY)
  eq(anna.tags, { "kunde" })
  local again = one({ op = "contact_new", area = "lib.nvim", name = "Anna Muster" })
  eq(again.id, "lib.nvim/anna-muster-2", "a taken id gets a counter")
  eq(
    one({ op = "contact_new", area = "lib.nvim", name = "X", slug = "anna-muster" }).error.code,
    "exists"
  )
  -- one namespace: a task, a meeting and a contact never share an id
  eq(
    one({ op = "contact_new", area = "lib.nvim", name = "Prep" }).id,
    "lib.nvim/prep-2",
    "a task has `prep`"
  )
  F.task(H, root, "lib.nvim", "anna-muster-3", F.meta("A task", "open"))
  eq(
    one({ op = "contact_new", area = "lib.nvim", name = "Anna Muster" }).id,
    "lib.nvim/anna-muster-4"
  )
  eq(
    one({
      op = "meeting_new",
      area = "lib.nvim",
      title = "Sync",
      fields = { date = "2026-10-20" },
      slug = "anna-muster",
    }).error.code,
    "exists",
    "and a meeting meets a contact"
  )
  eq(
    one({ op = "new", area = "lib.nvim", title = "Anna Muster", fields = { slug = "anna-muster" } }).error
      ~= nil,
    true,
    "and a task meets a contact"
  )

  -- the refusals: the message never names the value
  local bad_mail = one({
    op = "contact_new",
    area = "lib.nvim",
    name = "Zed",
    fields = { emails = { "zed-" .. MAIL .. "@@" } },
  })
  eq(bad_mail.ok, false)
  eq(bad_mail.error.code, "invalid_argument")
  ok(not bad_mail.error.message:find("rick", 1, true), bad_mail.error.message)
  has(bad_mail.error.message, "emails")
  local bad_phone = one({
    op = "contact_new",
    area = "lib.nvim",
    name = "Zed",
    fields = { phones = { "12345" } },
  })
  eq(bad_phone.error.code, "invalid_argument")
  ok(not bad_phone.error.message:find("12345", 1, true), bad_phone.error.message)
  eq(
    one({ op = "contact_new", area = "lib.nvim", name = "Zed", fields = { tz = "Vienna" } }).error.code,
    "invalid_argument"
  )
  eq(
    one({ op = "contact_new", area = "lib.nvim", name = "Zed", fields = { color = "red" } }).error.code,
    "invalid_argument"
  )
  eq(one({ op = "contact_new", area = "nowhere", name = "Zed" }).error.code, "invalid_argument")
  eq(
    one({ op = "contact_new", area = "lib.nvim", name = "Zed\nTwo" }).error.code,
    "invalid_argument"
  )
  ok(not H.exists(root .. "/lib.nvim/CONTACTS/zed.md"), "a refused contact leaves no file")

  -- a contact lives in any area: no place is asked for, no warning is given (decision D3)
  local elsewhere = one({ op = "contact_new", area = "ALL", name = "Elsewhere" })
  ok(elsewhere.ok, vim.inspect(elsewhere))
  eq(elsewhere.notes, nil)

  -- ── contact_set ──
  local before = read("lib.nvim/anna-muster")
  local set = one({
    op = "contact_set",
    id = "lib.nvim/anna-muster",
    patch = { role = "Sales", emails = { "anna@example.org", "a2@example.org" }, org = vim.NIL },
    if_match = before.etag,
  })
  ok(set.ok, vim.inspect(set))
  eq(set.outcome, "changed")
  local after = read("lib.nvim/anna-muster")
  eq(after.role, "Sales")
  eq(after.org, nil)
  eq(#after.emails, 2)
  eq(after.updated, F.TODAY)
  eq(set.inverse.op, "contact_set")
  eq(set.inverse.if_match, after.etag)
  local undone = one(set.inverse)
  ok(undone.ok, vim.inspect(undone))
  local restored = read("lib.nvim/anna-muster")
  eq(restored.org, "Muster AG")
  eq(restored.role, nil)
  eq(restored.emails, { "anna@example.org" })
  -- the stale version is a conflict, and a conflict names no mail
  local stale = one({
    op = "contact_set",
    id = "lib.nvim/anna-muster",
    patch = { role = "x" },
    if_match = before.etag,
  })
  eq(stale.error.code, "conflict")
  eq(
    one({ op = "contact_set", id = "lib.nvim/anna-muster", patch = { name = "" } }).error.code,
    "invalid_argument"
  )
  eq(
    one({ op = "contact_set", id = "lib.nvim/nobody", patch = { role = "x" } }).error.code,
    "not_found"
  )
  eq(
    one({ op = "contact_set", id = "lib.nvim/anna-muster", patch = { emails = { "nope" } } }).error.code,
    "invalid_argument"
  )
  eq(read("lib.nvim/anna-muster").emails, { "anna@example.org" }, "a refused patch changes nothing")
  eq(
    one({ op = "contact_set", id = "lib.nvim/anna-muster", patch = { role = "same" } }).outcome,
    "changed"
  )
  eq(
    one({ op = "contact_set", id = "lib.nvim/anna-muster", patch = { role = "same" } }).outcome,
    "unchanged"
  )

  -- ── contact_delete ──
  local to_delete = read("lib.nvim/anna-muster")
  local gone_dry = one({ op = "contact_delete", id = "lib.nvim/anna-muster" }, true)
  eq(gone_dry.outcome, "would_delete")
  ok(H.exists(to_delete.path), "a dry run deletes nothing")
  eq(
    one({ op = "contact_delete", id = "lib.nvim/anna-muster", if_match = before.etag }).error.code,
    "conflict"
  )
  local gone =
    one({ op = "contact_delete", id = "lib.nvim/anna-muster", if_match = to_delete.etag })
  ok(gone.ok, vim.inspect(gone))
  eq(gone.outcome, "deleted")
  ok(not H.exists(to_delete.path))
  eq(gone.inverse.op, "contact_new")
  eq(gone.inverse.id, "lib.nvim/anna-muster")
  local back = one(gone.inverse)
  ok(back.ok, vim.inspect(back))
  eq(back.id, "lib.nvim/anna-muster")
  local again_read = read("lib.nvim/anna-muster")
  eq(again_read.name, "Anna Muster")
  eq(again_read.emails, { "anna@example.org" })
  eq(again_read.phones, { PHONE })
  eq(again_read.role, "same")
  eq(one({ op = "contact_delete", id = "lib.nvim/nobody" }).error.code, "not_found")
  -- a folder holding more than the contact file is not deleted
  vim.fn.mkdir(root .. "/lib.nvim/CONTACTS/with-files/assets", "p")
  H.write(root .. "/lib.nvim/CONTACTS/with-files/with-files.md", "---\nname: With Files\n---\n")
  H.write(root .. "/lib.nvim/CONTACTS/with-files/assets/card.txt", "card")
  eq(one({ op = "contact_delete", id = "lib.nvim/with-files" }).error.code, "conflict")
  ok(H.exists(root .. "/lib.nvim/CONTACTS/with-files/assets/card.txt"))

  -- ── move_area: a contact keeps its place, only its id is in the way ──
  F.task(H, root, "lib.nvim", "rick", F.meta("Rick task", "open"))
  require("tasks_nvim.index").write_area("lib.nvim", { root = root })
  contact_file("cascade.nvim", "rick", "---\nname: Rick In Cascade\n---\n")
  local preview = one({ op = "move_area", id = "lib.nvim/rick", to_area = "cascade.nvim" }, true)
  eq(preview.outcome, "blocked")
  has(preview.move.conflicts[1].message, "contact")
  local refused = one({ op = "move_area", id = "lib.nvim/rick", to_area = "cascade.nvim" })
  eq(refused.ok, false)
  ok(H.exists(root .. "/lib.nvim/ROADMAP/tasks/rick.md"), "the task stays")
  ok(read("cascade.nvim/rick").valid, "and the contact too")
  eq(
    one({ op = "move_area", id = "lib.nvim/prep", to_area = "cascade.nvim" }).ok,
    true,
    "another task moves"
  )
  eq(read("lib.nvim/anna-muster").name, "Anna Muster", "no contact follows a task")

  -- ── the rule, with the failure messages of the door ──
  -- a mail address in the wrong field: the document and the answers of the door say which field, never the value
  local _, leak_text = call("contact", { id = "lib.nvim/leak" })
  ok(not leak_text:find("rick@", 1, true), "a mail in the document: " .. leak_text)
  has(leak_text, "contact-bad-tz")
  local patched = one({ op = "contact_set", id = "lib.nvim/anna-muster", patch = { tz = MAIL } })
  eq(patched.ok, false)
  eq(patched.error.code, "invalid_argument")
  local patched_text = vim.json.encode(patched)
  ok(not patched_text:find("rick@", 1, true), "a mail in an error: " .. patched_text)
  local made_bad =
    one({ op = "contact_new", area = "lib.nvim", name = "Leak 2", fields = { tz = MAIL } })
  ok(
    not vim.json.encode(made_bad):find("rick@", 1, true),
    "a mail in an error: " .. vim.inspect(made_bad)
  )
  eq(made_bad.error.code, "invalid_argument")
  -- a dry run and a conflict say the same
  local conflict = one({
    op = "contact_set",
    id = "lib.nvim/anna-muster",
    patch = { role = PHONE },
    if_match = "sha256:0000000000000000",
  })
  eq(conflict.error.code, "conflict")
  ok(not vim.json.encode(conflict):find("2345678", 1, true), vim.inspect(conflict))
  -- the contacts listing stays complete: the incomplete notes are scrubbed too
  local _, all_text = call("contacts", {})
  ok(not all_text:find('incomplete":["', 1, true), "nothing incomplete")
end
