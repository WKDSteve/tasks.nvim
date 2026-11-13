-- TESTS/tasks_remind_to_spec.lua -- `remind_to`, the e-mail addresses a reminder of its `remind` day goes to: the model
-- (an address, more than ten, addresses without a day), set (a comma list, on an open and a finished task; taking the
-- day away takes them with it; addresses without a day are refused), reopen (drops them) and the contract.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local model = require("tasks_nvim.model")
  local mutate = require("tasks_nvim.mutate")
  local contract = require("tasks_nvim.contract")

  -- ── an address ─────────────────────────────────────────────────────────────
  for _, good in ipairs({
    "a@example.org",
    "first.last+tag@mail.example.co.uk",
    "x_y-z@sub-domain.example.at",
  }) do
    ok(model.is_email(good), "an address: " .. good)
  end
  for _, bad in ipairs({
    "",
    "plain",
    "a@b",
    "a@@example.org",
    "a b@example.org",
    "A <a@example.org>",
    "a@example..org",
    "a@example.org,b@example.org",
    "a@.example.org",
    "a@example.1",
    42,
  }) do
    ok(not model.is_email(bad), "no address: " .. tostring(bad))
  end

  -- ── the frontmatter ────────────────────────────────────────────────────────
  local function parse(front)
    return model.parse_text(
      "---\ntitle: A\nstatus: open\n" .. front .. "created: 2026-01-01\n---\n\nBody.\n",
      { path = "/v/a/ROADMAP/tasks/a.md", area = "a" }
    )
  end
  local function hint_codes(task)
    local out = {}
    for _, h in ipairs(task.hints) do
      out[#out + 1] = h.code
    end
    return out
  end
  local good = parse("remind: 2026-11-20\nremind_to: [a@example.org, b@example.org]\n")
  eq({ good.remind_to, good.valid }, { { "a@example.org", "b@example.org" }, true })
  eq(hint_codes(good), {})
  local bad = parse("remind: 2026-11-20\nremind_to: [not-an-address]\n")
  ok(vim.tbl_contains(bad.error_codes, "bad-email"), table.concat(bad.error_codes, ","))
  local many = {}
  for i = 1, 11 do
    many[#many + 1] = ("p%d@example.org"):format(i)
  end
  local too_many = parse("remind: 2026-11-20\nremind_to: [" .. table.concat(many, ", ") .. "]\n")
  ok(vim.tbl_contains(too_many.error_codes, "bad-email"), "more than ten addresses")
  eq(
    hint_codes(parse("remind_to: [a@example.org]\n")),
    { "remind-to-without-remind" },
    "addresses without a day are a warning"
  )

  -- ── set ────────────────────────────────────────────────────────────────────
  local root = F.vault(H)
  local o = { root = root, today = "2026-11-10", index = false }
  local made =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Send the invoice" })))
  has(select(2, mutate.set(made.id, { remind_to = "a@example.org" }, o)), "needs a remind day")
  has(
    select(2, mutate.set(made.id, { remind = "2026-11-20", remind_to = "a@example.org, nope" }, o)),
    "not an e-mail address"
  )
  has(
    select(
      2,
      mutate.set(made.id, { remind = "2026-11-20", remind_to = table.concat(many, ",") }, o)
    ),
    "at most 10"
  )
  assert(
    mutate.set(
      made.id,
      { remind = "2026-11-20", remind_to = "a@example.org, B@example.org, A@example.org" },
      o
    )
  )
  local doc = assert(contract.task(made.id, { root = root }))
  eq(doc.task.remind_to, { "a@example.org", "B@example.org" }, "once each, without regard to case")

  -- taking the day away takes the addresses (and an hour) with it
  assert(mutate.set(made.id, { remind_at = "09:00" }, o))
  assert(mutate.set(made.id, { remind = mutate.REMOVE }, o))
  local text = H.read(made.path)
  ok(not text:find("remind", 1, true), "no remind key is left:\n" .. text)

  -- ── a finished task: set takes the remind keys, reopen drops them ──────────
  local fin =
    assert(mutate.new("lib.nvim", vim.tbl_extend("force", o, { title = "Renew the domain" })))
  assert(mutate.done(fin.id, vim.tbl_extend("force", o, { yes = true })))
  assert(mutate.set(fin.id, { remind = "2026-12-01", remind_to = "a@example.org" }, o))
  local snap = assert(contract.snapshot({ root = root }))
  local found
  for _, r in ipairs(snap.reminders or {}) do
    if r.id == fin.id then
      found = r
    end
  end
  eq(found and found.remind_to, { "a@example.org" }, "reminders carry the addresses")
  assert(mutate.reopen(fin.id, vim.tbl_extend("force", o, { status = "open" })))
  local reopened = assert(require("tasks_nvim.scan").find(fin.id, { root = root }))
  eq(
    { reopened.remind, reopened.remind_to },
    { nil, nil },
    "reopening drops the reminder and its addresses"
  )
end
