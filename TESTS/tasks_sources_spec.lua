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
      elseif path == "/otherhost" then
        -- the same server under another name: a different host as far as the table is concerned
        status = "301 Moved Permanently"
        extra = "Location: http://localhost:" .. server:getsockname().port .. "/ok\r\n"
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
  -- another HOST is never taken by --fix alone (a domain that changed hands may send anywhere): `kept`, old -> new
  -- named; the same host with another path (/moved -> /ok above) is taken
  local hostdoc = root .. "/host.md"
  H.write(hostdoc, table_doc({ "/otherhost", "/moved" }))
  local hbefore = H.read(hostdoc)
  res = run({ "check", "--sources", hostdoc, "--fix", "--timeout=1" })
  has(
    res.out,
    "kept\t"
      .. hostdoc
      .. ":7\t"
      .. base
      .. "/otherhost\tother host, check by hand (--allow-host-change)"
  )
  has(res.out, "fixed\t" .. hostdoc .. ":8\t" .. base .. "/moved -> " .. base .. "/ok")
  has(res.out, "; 1 link(s) rewritten")
  local htext = H.read(hostdoc)
  has(htext, "| [/otherhost](" .. base .. "/otherhost) |", "the link of another host stays")
  has(htext, "| [/moved](" .. base .. "/ok) |")
  -- with the switch it is taken, and the line says what changed
  H.write(hostdoc, hbefore)
  res = run({ "check", "--sources", hostdoc, "--fix", "--allow-host-change", "--timeout=1" })
  has(
    res.out,
    "fixed\t"
      .. hostdoc
      .. ":7\t"
      .. base
      .. "/otherhost -> http://localhost:"
      .. base:match(":(%d+)$")
      .. "/ok"
  )
  has(H.read(hostdoc), "| [/otherhost](http://localhost:" .. base:match(":(%d+)$") .. "/ok) |")
  eq(run({ "check", "--allow-host-change" }).code, 2, "--allow-host-change belongs to --sources")
  -- the comparison alone: www., case and port do not make another host; another host does, also behind user info
  eq(sources.safe_target("https://a.example/x", "https://www.a.example/y"), true)
  eq(sources.safe_target("https://www.A.example/x", "https://a.EXAMPLE:443/y"), true)
  eq(sources.safe_target("http://a.example/x", "https://a.example/x"), true, "http to https")
  local host_ok, host_why = sources.safe_target("https://a.example/x", "https://b.example/x")
  eq(host_ok, false)
  has(host_why, "other host")
  eq(
    sources.safe_target("https://a.example/x", "https://a.example@b.example/x"),
    false,
    "user info"
  )
  eq(sources.safe_target("https://a.example/x", "https://a.example.evil.example/x"), false)
  eq(sources.safe_target("https://a.example/x", "https://b.example/x", true), true, "allowed")

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
  eq(sources.safe_target("https://a.example/x/y", "https://b.example/z?q=1#s", true), true)
  eq(
    sources.safe_target("https://a.example", "https://b.example/", true),
    true,
    "a front page stays a front page"
  )
  eq(sources.safe_target("https://a.example/x", "https://b.example/", true), false)
  eq(sources.safe_target("https://a.example/x", "https://b.example/a b", true), false)
  eq(sources.safe_target("https://a.example/x", "https://b.example/a|b", true), false)
  eq(sources.safe_target("https://a.example/x", "https://b.example/a<b", true), false)
  eq(sources.safe_target("https://a.example/x", "javascript:alert(1)", true), false)
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

  -- ── a single-page app answers 200 for any path (help.sap.com): `unverified`, not `ok` ──
  local spa_url = "https://help.sap.com/docs/NOT_A_PRODUCT_XYZ"
  eq(sources.classify({ code = 200, redirects = 0, final = spa_url }), "unverified")
  eq(
    sources.classify({ code = 200, redirects = 1, final = "https://www.HELP.sap.com/x" }),
    "unverified",
    "a redirect onto the host counts too, compared without www. and case"
  )
  eq(
    sources.classify({ code = 404, redirects = 0, final = spa_url }),
    "dead",
    "a 404 is still dead"
  )
  eq(sources.classify({ code = 200, redirects = 0, final = "https://sap.com/x" }), "ok")
  local spa_doc = table.concat({
    "## Quellen",
    "",
    "| Quelle | Typ | Worauf achten | Zugang | Geprüft |",
    "| --- | --- | --- | --- | --- |",
    "| [SAP](" .. spa_url .. ") | Doku | x | frei | ungeprüft |",
    "",
  }, "\n")
  -- the fake of the HTTP access: 200 and an HTML "not found" page for any path, as the SPA does
  local spa = sources.check_text(spa_doc, {
    probe = function(url, _, done)
      done({ code = 200, redirects = 0, final = url, timeout = false, method = "HEAD" })
    end,
  })
  eq(spa[1].state, "unverified")
  has(sources.cell(spa[1], "2026-11-28"), "Single-Page-App, Inhalt im Browser prüfen 2026-11-28")
  -- the CLI: a host named with --spa-host (here the local server) is unverified, no exit 1, counted
  H.write(doc, table_doc({ "/ok" }))
  local spa_run = run({ "check", "--sources", doc, "--spa-host=127.0.0.1" })
  eq(spa_run.code, 0, spa_run.out .. spa_run.err)
  has(spa_run.out, "unverified\t")
  has(spa_run.out, "(SPA: check in the browser)")
  has(spa_run.out, "1 unverified (SPA)")
  eq(run({ "check", "--sources", doc, "--spa-host=" }).code, 2, "an empty --spa-host is refused")
  eq(run({ "check", "--spa-host=x" }).code, 2, "--spa-host belongs to --sources")

  -- ── --fix does not pin an evergreen link to today's version or date ──
  local function moved_doc(urls)
    local lines = {
      "## Quellen",
      "",
      "| Quelle | Typ | Worauf achten | Zugang | Geprüft |",
      "| --- | --- | --- | --- | --- |",
    }
    for _, u in ipairs(urls) do
      lines[#lines + 1] = ("| [x](%s) | Doku | x | frei | ungeprüft |"):format(u)
    end
    return table.concat(lines, "\n") .. "\n"
  end
  -- the fakes of the HTTP access: every link moved, permanently, to the target of the table
  local function fix_with(targets, extra)
    return sources.check_text(
      moved_doc(vim.tbl_keys(targets)),
      vim.tbl_extend("force", {
        fix = true,
        probe = function(url, _, done)
          done({ code = 200, redirects = 1, final = targets[url], timeout = false, method = "HEAD" })
        end,
        resolve = function(url, _, done)
          done(targets[url])
        end,
      }, extra or {})
    )
  end
  local function by_url(results)
    local out = {}
    for _, r in ipairs(results) do
      out[r.row.url] = r
    end
    return out
  end
  local pins = {
    ["https://learn.microsoft.com/en-us/aspnet/core/"] = "https://learn.microsoft.com/en-us/aspnet/core/?view=aspnetcore-11.0",
    ["https://modelcontextprotocol.io"] = "https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro",
    ["https://a.example/guide/latest/intro"] = "https://a.example/guide/3.2/intro",
    ["https://a.example/old/page"] = "https://a.example/new/page",
  }
  local held = by_url(fix_with(pins))
  has(held["https://learn.microsoft.com/en-us/aspnet/core/"].kept or "", "only a query was added")
  has(held["https://modelcontextprotocol.io"].kept or "", "target path carries a version or date")
  has(held["https://a.example/guide/latest/intro"].kept or "", "a version or date")
  eq(
    held["https://a.example/old/page"].fixed,
    "https://a.example/new/page",
    "an unversioned move is fixed"
  )
  for url, r in pairs(held) do
    if url ~= "https://a.example/old/page" then
      eq(r.fixed, nil, url .. " is not rewritten")
    end
  end
  local taken = by_url(fix_with(pins, { allow_version_pin = true }))
  eq(
    taken["https://modelcontextprotocol.io"].fixed,
    pins["https://modelcontextprotocol.io"],
    "--allow-version-pin takes it"
  )
  eq(
    sources.pins_version("https://a.example/v2/x", "https://a.example/v2/y"),
    nil,
    "a version it had"
  )
  has(sources.pins_version("https://a.example/x", "https://a.example/v2.1/x") or "", "version")
  eq(run({ "check", "--allow-version-pin" }).code, 2, "--allow-version-pin belongs to --sources")

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
