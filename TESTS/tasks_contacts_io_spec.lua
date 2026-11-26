-- TESTS/tasks_contacts_io_spec.lua -- contacts in and out as vCard (3.0, 4.0) and CSV (`tasks_nvim.contacts_io`, the
-- CLI `tasks contacts import|export`): the readers on real example files (TESTS/fixtures/contacts), what has no field
-- is named, a duplicate mail is reported and never overwrites, a dry run writes nothing, the writers round-trip, and no
-- message names a mail address or a phone number.
-- @scans-data: the folders it lists are the fixture vault in the temp folder

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(here .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local contact_write = require("tasks_nvim.contact_write")
  local contacts = require("tasks_nvim.contacts")
  local io_ = require("tasks_nvim.contacts_io")

  local function fixture(name)
    local f = assert(io.open(here .. "/fixtures/contacts/" .. name, "rb"))
    local t = f:read("*a")
    f:close()
    return t, here .. "/fixtures/contacts/" .. name
  end

  local root = F.vault(H)
  local function run(argv)
    local out, err = {}, {}
    local args = vim.list_extend(vim.deepcopy(argv), { "--vault=" .. root, "--today=" .. F.TODAY })
    local code = cli.run(args, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end
  local function area_files(area)
    local list = contacts.area(area, { root = root })
    return list
  end
  local function no_personal(text, what)
    ok(not text:find("@", 1, true), what .. " names a mail address: " .. text)
    ok(not text:find("%d%d%d%d%d%d%d"), what .. " names a phone number: " .. text)
  end

  -- ── vCard 3.0 ──
  local v3, v3_path = fixture("outlook-v3.vcf")
  local recs, msgs = io_.parse_vcf(v3)
  eq(#recs, 2, vim.inspect(msgs))
  local a = recs[1]
  eq(a.name, "Dr. Jörg Müller")
  eq(a.org, "Beispiel GmbH / Support")
  eq(a.role, "Senior Engineer, T2")
  eq(a.emails, { "joerg.mueller@example.org", "j.mueller@example.net" })
  eq(a.phones, { "+43 660 1234567", "+49 (30) 1234 5678" })
  eq(a.tags, { "kunde", "t2" })
  eq(a.notes, "Prefers mail.\nCalls only after 10, please.")
  -- what has no field is named, not silently lost (and no value is quoted)
  local dropped = table.concat(a.problems, "|")
  has(dropped, "ADR")
  has(dropped, "BDAY")
  has(dropped, "PHOTO")
  has(dropped, "X-CUSTOM-FIELD")
  ok(not dropped:find("Hauptstrasse", 1, true), "a value of a dropped field is quoted")
  -- a folded line is one line again
  ok(
    recs[2].name:find("Seventy%-Five Octets Surely Indeed") or recs[2].name:find("SurelyIndeed"),
    recs[2].name
  )
  -- CRLF line ends and a byte order mark read the same
  local crlf = io_.parse_vcf("\239\187\191" .. v3:gsub("\n", "\r\n"))
  eq(crlf[1].name, a.name)

  -- ── vCard 4.0: tel: URIs, N as a fallback, bad values named without their value ──
  local v4 = fixture("mixed-v4.vcf")
  local r4 = io_.parse_vcf(v4)
  eq(#r4, 5)
  eq(r4[1].phones, { "+43-1-2345678" })
  eq(r4[3].name, "Eva Meier")
  ok(r4[4].fatal, "a card without any name is refused")

  -- ── CSV: delimiter named, quotes, line break in a cell, unknown column named ──
  local csv, csv_path = fixture("people-semicolon.csv")
  local rows, cmsgs = io_.parse_csv(csv)
  eq(#rows, 3, vim.inspect(cmsgs))
  has(cmsgs[1], "delimiter: ;")
  has(cmsgs[1], "UTF-8")
  has(table.concat(cmsgs, "|"), "Geburtstag")
  eq(rows[1].name, "Zoë Ångström")
  eq(rows[1].org, 'Büro "Nord"')
  eq(rows[1].notes, "Zeile eins\nZeile zwei; mit Semikolon")
  eq(rows[1].tz, "Europe/Stockholm")
  ok(rows[3].fatal, "a row without a name is refused")
  local bom, bom_path = fixture("bom-comma.csv")
  local brows, bmsgs = io_.parse_csv(bom)
  eq(brows[1].name, "Bom Person", vim.inspect(bmsgs))
  eq(brows[1].emails, { "bom@example.org" })
  has(bmsgs[1], "delimiter: ,")
  -- text that is no UTF-8 is refused with a word, not read as garbage
  local none, why = io_.parse_csv("name,email\nJos\252,x@example.org\n")
  eq(none, nil)
  has(why[1], "UTF-8")
  -- a header without a name column
  local nn, nwhy = io_.parse_csv("email\na@example.org\n")
  eq(nn, nil)
  has(nwhy[1], "name column")
  -- an explicit delimiter wins over the detected one
  local forced = io_.parse_csv("name;org,x\nA;B,C\n", { delimiter = ";" })
  eq(forced[1].name, "A")
  eq(io_.parse_csv("name;org,x\nA;B,C\n"), nil, "a tie falls back to the comma")

  -- ── import: dry run writes nothing ──
  local held = assert(contact_write.new("lib.nvim", {
    root = root,
    today = F.TODAY,
    name = "Held Person",
    fields = { emails = { "held@example.org" } },
  }))
  local before = #area_files("lib.nvim")
  local dry = run({ "contacts", "import", v3_path, "--area=lib.nvim", "--dry-run" })
  eq(dry.code, 0, dry.err)
  has(dry.out, "would-create\tlib.nvim/dr-joerg-mueller")
  eq(#area_files("lib.nvim"), before, "a dry run wrote a file")

  -- ── import: real run, then the same file again (all duplicates, nothing overwritten) ──
  local imp = run({ "contacts", "import", v3_path, "--area=lib.nvim" })
  eq(imp.code, 0, imp.err)
  has(imp.out, "created: 2, duplicates: 0, refused: 0")
  has(imp.err, "not imported (no field for it)")
  no_personal(imp.out, "the import output")
  no_personal(imp.err, "the import warnings")
  local c = assert(contacts.find("lib.nvim/dr-joerg-mueller", { root = root }))
  ok(c.valid, vim.inspect(c.errors))
  eq(c.org, "Beispiel GmbH / Support")
  eq(c.emails, { "joerg.mueller@example.org", "j.mueller@example.net" })
  eq(c.tags, { "kunde", "t2" })
  eq(c.notes, "Prefers mail.\nCalls only after 10, please.")
  local path = c.path
  local text_before = assert(io.open(path, "rb")):read("*a")
  local again = run({ "contacts", "import", v3_path, "--area=lib.nvim" })
  eq(again.code, 0, again.err)
  has(again.out, "created: 0, duplicates: 2, refused: 0")
  has(again.out, "duplicate\tlib.nvim/dr-joerg-mueller")
  eq(assert(io.open(path, "rb")):read("*a"), text_before, "a duplicate overwrote the contact")

  -- ── import: mixed file: duplicates inside the file and against the vault, refused, invalid values ──
  local mixed = run({ "contacts", "import", select(2, fixture("mixed-v4.vcf")), "--area=lib.nvim" })
  eq(mixed.code, 0, mixed.err)
  has(mixed.out, "created: 2, duplicates: 2, refused: 1")
  -- the card with the same mail in another case is a duplicate of the first card of the file
  has(mixed.out, "duplicate\tlib.nvim/rick-beispiel\t#2")
  -- the card with the mail of an existing contact
  has(mixed.out, "duplicate\t" .. held.id .. "\t#5")
  has(mixed.out, "refused\t#4")
  has(mixed.err, "tz is no time zone")
  has(mixed.err, "an email address is invalid")
  has(mixed.err, "a phone number is invalid")
  no_personal(mixed.out, "the import output")
  no_personal(mixed.err, "the import warnings")
  local eva = assert(contacts.find("lib.nvim/eva-meier", { root = root }))
  ok(eva.valid, vim.inspect(eva.errors))
  eq(eva.emails, { "eva@example.org" })
  eq(eva.tz, nil)

  -- ── import CSV (semicolon, umlauts) and the JSON report ──
  local ic = run({ "contacts", "import", csv_path, "--area=cascade.nvim", "--lang=en" })
  eq(ic.code, 0, ic.err)
  has(ic.out, "created: 2, duplicates: 0, refused: 1")
  has(ic.err, "delimiter: ;")
  local zoe = assert(contacts.find("cascade.nvim/zoe-angstroem", { root = root }))
  ok(zoe.valid, vim.inspect(zoe.errors))
  eq(zoe.name, "Zoë Ångström")
  eq(zoe.notes, "Zeile eins\nZeile zwei; mit Semikolon")
  local js =
    run({ "contacts", "import", bom_path, "--area=cascade.nvim", "--dry-run", "--format=json" })
  eq(js.code, 0, js.err)
  local rep = vim.json.decode(js.out)
  eq(rep.dry_run, true)
  eq(#rep.created, 1)
  no_personal(js.out, "the JSON report")

  -- ── import: usage errors ──
  eq(run({ "contacts", "import", v3_path }).code, 2, "no --area")
  local nofmt = run({ "contacts", "import", here .. "/fixture.lua", "--area=lib.nvim" })
  eq(nofmt.code, 2)
  has(nofmt.err, "format")
  local missing = run({ "contacts", "import", here .. "/fixtures/none.vcf", "--area=lib.nvim" })
  eq(missing.code, 2)
  local noarea = run({ "contacts", "import", bom_path, "--area=nowhere" })
  eq(noarea.code, 0)
  has(noarea.out, "refused: 1")
  has(noarea.out, "unknown area")

  -- ── export and round trip ──
  local out_vcf = run({ "contacts", "export", "--format=vcf", "lib.nvim" })
  eq(out_vcf.code, 0, out_vcf.err)
  -- stdout is cleaned for the terminal (`cli.clean` drops the CR); `--out=` keeps CRLF (below)
  has(out_vcf.out, "BEGIN:VCARD\nVERSION:4.0\nFN:Dr. Jörg Müller\n")
  has(out_vcf.out, "TITLE:Senior Engineer\\, T2\n")
  has(out_vcf.out, "NOTE:Prefers mail.\\nCalls only after 10\\, please.\n")
  has(out_vcf.out, "CATEGORIES:kunde,t2\n")
  for line in out_vcf.out:gmatch("[^\r\n]+") do
    ok(#line <= 75, "an unfolded long line: " .. line)
  end
  local back = io_.parse_vcf(out_vcf.out)
  local by_name = {}
  for _, r in ipairs(back) do
    by_name[r.name] = r
  end
  eq(by_name["Dr. Jörg Müller"].emails, a.emails)
  eq(by_name["Dr. Jörg Müller"].notes, a.notes)
  eq(by_name["Dr. Jörg Müller"].org, a.org)
  local v3out = run({ "contacts", "export", "--format=vcf", "--version=3", "lib.nvim" })
  has(v3out.out, "VERSION:3.0\n")
  has(v3out.out, "EMAIL;TYPE=INTERNET:")
  eq(run({ "contacts", "export", "--format=vcf", "--version=9" }).code, 2)

  local out_csv =
    run({ "contacts", "export", "--format=csv", "--delimiter=;", "--bom", "cascade.nvim" })
  eq(out_csv.code, 0, out_csv.err)
  eq(out_csv.out:sub(1, 3), "\239\187\191")
  has(out_csv.out, "name;org;role;emails;phones;tz;tags;notes\n")
  local crows = io_.parse_csv(out_csv.out)
  local zrow
  for _, r in ipairs(crows) do
    if r.name == "Zoë Ångström" then
      zrow = r
    end
  end
  eq(zrow.org, 'Büro "Nord"')
  eq(zrow.notes, "Zeile eins\nZeile zwei; mit Semikolon")
  eq(zrow.emails, { "zoe@example.org" })

  -- the filter and the file output
  local only = run({ "contacts", "export", "--format=csv", "--tag=kunde" })
  has(only.out, "Dr. Jörg Müller")
  ok(not only.out:find("Eva Meier", 1, true), "the tag filter let another contact pass")
  local target = H.tmpdir() .. "/out.vcf"
  local to_file = run({ "contacts", "export", "--format=vcf", "--out=" .. target })
  eq(to_file.code, 0, to_file.err)
  has(to_file.out, "exported\t")
  has(assert(io.open(target, "rb")):read("*a"), "BEGIN:VCARD\r\nVERSION:4.0\r\n")
  eq(run({ "contacts", "export" }).code, 2, "export needs a format")

  -- ── a CSV cell that starts like a spreadsheet formula is text (`'` in front), and comes back unchanged ──
  local risky = {
    {
      name = '=HYPERLINK("http://x","y")',
      org = "+49 Org",
      role = "-1",
      emails = {},
      phones = { "+49 30 1234", "030 5678" },
      tz = nil,
      tags = { "@home" },
      notes = "\t=1+1",
    },
    -- a value that really begins with `'` before a formula start must survive the round trip too
    {
      name = "'=kept",
      org = "'plain",
      emails = {},
      phones = {},
      tags = {},
      notes = "  @ blank first",
    },
    { name = "Plain Name", org = "a=b", emails = {}, phones = {}, tags = {}, notes = "x-y" },
  }
  local guarded = io_.write_csv(risky)
  has(guarded, "'=HYPERLINK(", "a formula in a name is guarded")
  has(guarded, ",'+49 Org,", "a leading + is guarded")
  has(guarded, ",'-1,", "a leading - is guarded")
  has(guarded, ",'+49 30 1234;030 5678,", "a phone cell that starts with + is guarded once")
  has(guarded, ",'@home,", "a leading @ is guarded")
  has(guarded, "'\t=1+1", "a leading tab before a formula is guarded")
  has(
    guarded,
    "\r\nPlain Name,a=b,",
    "a cell with no formula start, and an = inside one, are untouched"
  )
  local back_rows = assert(io_.parse_csv(guarded))
  eq(back_rows[1].name, risky[1].name, "the name comes back without the guard")
  eq(back_rows[1].org, "+49 Org")
  eq(back_rows[1].role, "-1")
  eq(back_rows[1].phones, { "+49 30 1234", "030 5678" }, "the phones come back as the same numbers")
  eq(back_rows[1].tags, { "@home" })
  eq(
    back_rows[2].name,
    "'=kept",
    "a value that begins with ' and a formula start is not changed by the trip"
  )
  eq(back_rows[2].org, "'plain", "a ' before ordinary text is left alone")
  eq(back_rows[3].org, "a=b")
  -- a spreadsheet writes a leading ' for text typed with a leading +: the import takes it away
  eq(assert(io_.parse_csv("name,phones\nJo,'+49 30 1\n"))[1].phones, { "+49 30 1" })
  -- `raw` writes the cells as they are
  local plain = io_.write_csv(risky, { raw = true })
  has(plain, ",+49 Org,", "raw leaves a leading + alone")
  ok(not plain:find("'", 1, true) or plain:find("'=kept", 1, true), "raw adds no guard")
  -- through the CLI: a real contact with a phone that starts with + (Dr. Jörg Müller)
  local safe_cli = run({ "contacts", "export", "--format=csv", "--tag=kunde" })
  eq(safe_cli.code, 0, safe_cli.err)
  has(safe_cli.out, "'+43 660 1234567", "the CLI guards a phone that starts with +")
  local raw_cli = run({ "contacts", "export", "--format=csv", "--tag=kunde", "--raw" })
  eq(raw_cli.code, 0, raw_cli.err)
  has(raw_cli.out, ",+43 660 1234567", "--raw writes it as it is")
  ok(not raw_cli.out:find("'+43", 1, true), "--raw adds no guard")

  -- ── the writers escape and fold ──
  local long = {
    {
      name = "aÄ" .. ("ö"):rep(60),
      emails = {},
      phones = {},
      tags = { "a,b" },
      notes = "line\nbreak; semi\\colon",
    },
  }
  local vcf = io_.write_vcf(long)
  for line in vcf:gmatch("[^\r\n]+") do
    ok(#line <= 75, "line over 75 octets: " .. #line)
    ok(io_.is_utf8(line), "a fold cut inside a character")
  end
  local rt = io_.parse_vcf(vcf)
  eq(rt[1].name, long[1].name, "folding cut a character")
  eq(rt[1].notes, long[1].notes)
  eq(rt[1].tags, { "a,b" })

  -- ── the contract: `contacts_import` (an operation of `ops`) and `contacts_export` (a read method) ──
  local api = require("tasks_nvim.api")
  local root2 = F.vault(H)
  local function ops_call(op, is_dry)
    local text = api.call(
      "ops",
      vim.json.encode({ dry_run = is_dry == true, ops = { op } }),
      { root = root2, today = F.TODAY }
    )
    return vim.json.decode(text), text
  end
  local function read_call(method, params)
    local text = api.call(method, vim.json.encode({ params = params }), { root = root2 })
    return vim.json.decode(text), text
  end
  -- a dry run names what would be made and writes nothing
  local dry_doc, dry_text =
    ops_call({ op = "contacts_import", area = "lib.nvim", text = v3, as = "vcf" }, true)
  eq(dry_doc.kind, "tasks.result", dry_text)
  eq(dry_doc.results[1].ok, true, dry_text)
  eq(dry_doc.results[1].outcome, "would_create")
  eq(#dry_doc.results[1].report.created, 2, dry_text)
  eq(dry_doc.results[1].changed_ids, {})
  eq(#(contacts.area("lib.nvim", { root = root2 })), 0, "a dry run wrote a contact")
  no_personal(
    vim.json.encode(dry_doc.results[1].report.problems)
      .. vim.json.encode(dry_doc.results[1].report.messages),
    "the report of the operation"
  )
  -- the real run makes them, a second run reports duplicates with the holder's id and makes nothing
  local real = ops_call({ op = "contacts_import", area = "lib.nvim", text = v3, as = "vcf" })
  eq(real.results[1].outcome, "created")
  eq(#real.results[1].changed_ids, 2)
  eq(#(contacts.area("lib.nvim", { root = root2 })), 2)
  local twice = ops_call({ op = "contacts_import", area = "lib.nvim", text = v3, as = "vcf" })
  eq(twice.results[1].outcome, "unchanged")
  eq(#twice.results[1].report.duplicates, 2)
  eq(twice.results[1].report.duplicates[1].of, real.results[1].changed_ids[1])
  eq(#(contacts.area("lib.nvim", { root = root2 })), 2, "a duplicate was written")
  -- a CSV text with its delimiter named in the messages; refusals of the shape
  local csv_text = fixture("people-semicolon.csv")
  local csv_doc =
    ops_call({ op = "contacts_import", area = "cascade.nvim", text = csv_text, as = "csv" }, true)
  eq(csv_doc.results[1].ok, true, vim.inspect(csv_doc))
  ok(#csv_doc.results[1].report.created > 0)
  local bad_as =
    ops_call({ op = "contacts_import", area = "lib.nvim", text = v3, as = "ics" }, true)
  eq(bad_as.results[1].error.code, "invalid_argument")
  local no_area = ops_call({ op = "contacts_import", area = "nope", text = v3, as = "vcf" }, true)
  eq(no_area.results[1].error.code, "not_found")
  local huge = ops_call({
    op = "contacts_import",
    area = "lib.nvim",
    text = ("x"):rep(require("tasks_nvim.ops").MAX_IMPORT_TEXT + 1),
    as = "csv",
  }, true)
  eq(huge.results[1].error.code, "payload_too_large")
  -- the export as a document: the same text as the CLI writes, the formula guard included
  local xdoc, xtext = read_call("contacts_export", { format = "csv", area = "lib.nvim" })
  eq(xdoc.kind, "tasks.contacts_export", xtext)
  eq(xdoc.format, "csv")
  eq(xdoc.count, 2)
  has(xdoc.text, "'+43 660 1234567", "the export document guards a phone that starts with +")
  local xraw = read_call("contacts_export", { format = "csv", area = "lib.nvim", raw = true })
  has(xraw.text, ",+43 660 1234567")
  local xv = read_call("contacts_export", { format = "vcf", version = "3", tag = "kunde" })
  eq(xv.count, 1)
  has(xv.text, "BEGIN:VCARD\r\nVERSION:3.0\r\n")
  local round =
    ops_call({ op = "contacts_import", area = "cascade.nvim", text = xdoc.text, as = "csv" }, true)
  eq(
    round.results[1].report.duplicates[1].of ~= nil,
    true,
    "the export comes back as the same contacts"
  )
  eq(read_call("contacts_export", { format = "pdf" }).code, "invalid_argument")
  eq(read_call("contacts_export", { format = "vcf", bom = true }).code, "invalid_argument")
  eq(read_call("contacts_export", { format = "csv", area = "nope" }).code, "not_found")
end
