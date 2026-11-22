-- TESTS/tasks_sources_spec.lua -- `tasks check --sources`: the web links of the `## Quellen` table of a learning path are
-- asked (HEAD, GET as fallback), told apart (ok, moved, blocked, dead, no answer) and written into the column `Geprüft`.
-- A local test server answers 200, 301 -> 200, 403, 404, 405 on HEAD and never (a timeout).

---@diagnostic disable: need-check-nil, param-type-mismatch
return function(H)
  local eq, has, lacks = H.eq, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local cli = require("tasks_nvim.cli")
  local sources = require("tasks_nvim.sources")
  local uv = vim.uv

  if vim.fn.executable("curl") ~= 1 then
    print("n/a  curl is not installed")
    return
  end

  -- the server: one answer per path; the requests are counted
  local hits, conns = {}, {}
  local server = uv.new_tcp()
  server:bind("127.0.0.1", 0)
  server:listen(32, function()
    local c = uv.new_tcp()
    server:accept(c)
    conns[#conns + 1] = c
    c:read_start(function(err, data)
      if err or not data then
        return
      end
      local method, path = data:match("^(%u+) (%S+)")
      hits[#hits + 1] = method .. " " .. path
      local status, extra = "200 OK", ""
      if path == "/moved" then
        status, extra = "301 Moved Permanently", "Location: /ok\r\n"
      elseif path == "/temp" then
        status, extra = "302 Found", "Location: /ok\r\n"
      elseif path == "/chain" then
        status, extra = "308 Permanent Redirect", "Location: /moved\r\n"
      elseif path == "/home" then
        status, extra = "301 Moved Permanently", "Location: /\r\n"
      elseif path == "/bad" then
        status, extra = "301 Moved Permanently", "Location: /ok)x\r\n"
      elseif path == "/forbidden" then
        status = "403 Forbidden"
      elseif path == "/gone" then
        status = "404 Not Found"
      elseif path == "/nohead" and method == "HEAD" then
        status = "405 Method Not Allowed"
      elseif path == "/slow" then
        return -- no answer at all
      end
      c:write(
        "HTTP/1.1 " .. status .. "\r\n" .. extra .. "Content-Length: 0\r\nConnection: close\r\n\r\n"
      )
      c:shutdown()
    end)
  end)
  local port = server:getsockname().port
  local base = "http://127.0.0.1:" .. port

  local root = F.vault(H)
  local common = { "--vault=" .. root, "--today=2026-11-22" }
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(vim.list_extend(vim.deepcopy(argv), common), {
      out = function(x)
        out[#out + 1] = x
      end,
      err = function(x)
        err[#err + 1] = x
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end

  local doc = root .. "/pfad.md"
  local function table_doc(paths)
    local rows = {
      "# Pfad",
      "",
      "## Quellen",
      "",
      "| Quelle | Typ | Worauf achten | Zugang | Geprüft |",
      "| --- | --- | --- | --- | --- |",
    }
    for _, p in ipairs(paths) do
      rows[#rows + 1] = ("| [%s](%s%s) | Doku | x | frei | ungeprüft |"):format(p, base, p)
    end
    rows[#rows + 1] = "| [lokal](../x.pdf) | Buch | x | lokal | 2026-11-21 (Datei da) |"
    vim.list_extend(
      rows,
      { "", "## Lernpunkte", "", "- [ ] [kein Link](" .. base .. "/gone) Text", "" }
    )
    return table.concat(rows, "\n")
  end
  H.write(doc, table_doc({ "/ok", "/moved", "/forbidden", "/gone", "/nohead", "/slow" }))
  local before = H.read(doc)

  -- the classification and the table reader alone
  eq(sources.classify({ code = 200, redirects = 0 }), "ok")
  eq(sources.classify({ code = 200, redirects = 1 }), "redirected")
  eq(sources.classify({ code = 429, redirects = 0 }), "blocked")
  eq(sources.classify({ code = 410, redirects = 0 }), "dead")
  eq(sources.classify({ code = 503, redirects = 0 }), "error")
  eq(sources.classify({ code = 0, redirects = 0 }), "unreachable")
  local rows = sources.rows(before)
  eq(
    #rows,
    6,
    "only the web links of the Quellen table: not the local one, not the link under Lernpunkte"
  )
  eq(rows[1].url, base .. "/ok")

  -- without --sources nothing goes out, `check` included
  run({ "check" })
  run({ "check", doc })
  eq(#hits, 0, "no request without --sources")

  -- the report: dead is an error, blocked and moved are not
  local res = run({ "check", "--sources", doc, "--timeout=1" })
  eq(res.code, 1, res.err)
  has(res.out, "dead\t" .. doc .. ":10\t404\t" .. base .. "/gone")
  has(res.out, "blocked\t" .. doc .. ":9\t403\t" .. base .. "/forbidden")
  has(res.out, "redirected\t" .. doc .. ":8\t200 -> " .. base .. "/ok\t" .. base .. "/moved")
  has(res.out, "unreachable\t" .. doc .. ":12\t-")
  has(res.out, "(timeout)")
  lacks(res.out, "/nohead", "HEAD refused, GET answered: reachable")
  has(
    res.out,
    "6 link(s) in 1 file(s): 2 ok, 1 moved, 1 blocked (not checkable), 1 dead, 0 other error, 1 no answer"
  )
  eq(H.read(doc), before, "nothing is written without --write")
  local heads, gets = 0, 0
  for _, h in ipairs(hits) do
    heads = heads + (h:match("^HEAD") and 1 or 0)
    gets = gets + (h:match("^GET") and 1 or 0)
  end
  local enough = heads >= 6 and gets >= 3 -- every link by HEAD; /nohead, /forbidden, /gone again by GET
  eq(enough, true, vim.inspect(hits))

  -- --write: date and answer in the column, nothing else moves
  res = run({ "check", "--sources", doc, "--write", "--timeout=1" })
  eq(res.code, 1, res.err)
  local text = H.read(doc)
  has(text, "| [/ok](" .. base .. "/ok) | Doku | x | frei | erreichbar 2026-11-22 |")
  has(text, "| frei | erreichbar (umgeleitet) 2026-11-22 |")
  has(text, "| frei | abweisend, nicht prüfbar (403) 2026-11-22 |")
  has(text, "| frei | tot (404) 2026-11-22 |")
  has(text, "| frei | erreichbar 2026-11-22 |\n| [/slow]")
  has(text, "| frei | keine Antwort (Zeitlimit) 2026-11-22 |")
  has(text, "| [lokal](../x.pdf) | Buch | x | lokal | 2026-11-21 (Datei da) |")
  has(text, "- [ ] [kein Link](" .. base .. "/gone) Text")
  eq(
    select(2, text:gsub("\n", "\n")),
    select(2, before:gsub("\n", "\n")),
    "the same number of lines"
  )

  -- a folder: every .md below it; a file without a Quellen table has nothing to ask
  H.write(root .. "/ordner/leer.md", "# Nichts\n\n[x](" .. base .. "/gone)\n")
  local count = #hits
  res = run({ "check", "--sources", root .. "/ordner" })
  eq(res.code, 0, res.err)
  has(res.out, "0 link(s) in 1 file(s)")
  eq(#hits, count)

  -- --fix: a permanent redirect (301, 308, also a chain of them) is written into the link, nothing else moves
  local fixdoc = root .. "/fix.md"
  H.write(fixdoc, table_doc({ "/moved", "/chain", "/temp", "/home", "/bad", "/ok", "/gone" }))
  local fbefore = H.read(fixdoc)
  res = run({ "check", "--sources", fixdoc, "--timeout=1" })
  eq(H.read(fixdoc), fbefore, "without --fix the links stay")
  lacks(res.out, "fixed\t")
  res = run({ "check", "--sources", fixdoc, "--fix", "--timeout=1" })
  eq(res.code, 1, "a dead link still fails the run: " .. res.err)
  has(res.out, "fixed\t" .. fixdoc .. ":7\t" .. base .. "/moved -> " .. base .. "/ok")
  has(
    res.out,
    "fixed\t" .. fixdoc .. ":8\t" .. base .. "/chain -> " .. base .. "/ok",
    "a chain: the end"
  )
  has(res.out, "kept\t" .. fixdoc .. ":9\t" .. base .. "/temp\tno permanent redirect", "302 stays")
  has(res.out, "kept\t" .. fixdoc .. ":10\t" .. base .. "/home\tthe target is the front page")
  has(res.out, "kept\t" .. fixdoc .. ":11\t" .. base .. "/bad\tthe target is not a plain address")
  has(res.out, "; 2 link(s) rewritten")
  local ftext = H.read(fixdoc)
  has(
    ftext,
    "| [/moved](" .. base .. "/ok) | Doku | x | frei | ungeprüft |",
    "the target, the row as it was"
  )
  has(ftext, "| [/chain](" .. base .. "/ok) |")
  has(ftext, "| [/temp](" .. base .. "/temp) |")
  has(ftext, "| [/home](" .. base .. "/home) |")
  has(ftext, "| [/gone](" .. base .. "/gone) |")
  eq(
    select(2, ftext:gsub("\n", "\n")),
    select(2, fbefore:gsub("\n", "\n")),
    "the same number of lines"
  )
  -- both flags: the answer and the new address in one write
  H.write(fixdoc, fbefore)
  run({ "check", "--sources", fixdoc, "--fix", "--write", "--timeout=1" })
  ftext = H.read(fixdoc)
  has(
    ftext,
    "| [/moved](" .. base .. "/ok) | Doku | x | frei | erreichbar (umgeleitet) 2026-11-22 |"
  )
  -- the pieces: what may be written, and a fragment is kept
  local ok_new, why = sources.safe_target("https://a.example/x/y", "http://a.example/x/y")
  eq(ok_new, false)
  has(why, "http")
  eq(sources.safe_target("https://a.example/x/y", "https://b.example/z?q=1#s"), true)
  eq(
    sources.safe_target("https://a.example", "https://b.example/"),
    true,
    "a front page stays a front page"
  )
  eq(sources.safe_target("https://a.example/x", "https://b.example/"), false)
  eq(sources.safe_target("https://a.example/x", "https://b.example/a b"), false)
  eq(sources.safe_target("https://a.example/x", "https://b.example/a|b"), false)
  eq(sources.safe_target("https://a.example/x", "https://b.example/a<b"), false)
  eq(sources.safe_target("https://a.example/x", "javascript:alert(1)"), false)
  H.write(fixdoc, fbefore)
  local fixed_text = sources.apply(fbefore, {
    {
      row = sources.rows(fbefore)[1],
      state = "redirected",
      code = 200,
      redirects = 1,
      final = "",
      fixed = base .. "/ok#frag",
    },
  }, { fix = true })
  has(fixed_text, "| [/moved](" .. base .. "/ok#frag) | Doku | x | frei | ungeprüft |")

  -- usage
  eq(run({ "check", "--fix" }).code, 2, "--fix belongs to --sources")
  eq(run({ "check", "--sources", "--timeout=0" }).code, 2)
  eq(run({ "check", "--write" }).code, 2, "--write belongs to --sources")

  server:close()
  for _, c in ipairs(conns) do
    if not c:is_closing() then
      c:close()
    end
  end
end
