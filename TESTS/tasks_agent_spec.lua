-- TESTS/tasks_agent_spec.lua -- `:Tasks agent`: the hand-over of a task to ai-desktop's job intake (`tasks_nvim.agent`)
-- against a stand-in of ai-desktop on a TCP port of the test's own, and the fallback to a stand-in of ai.nvim.

---@diagnostic disable: need-check-nil, param-type-mismatch

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")
  local agent = require("tasks_nvim.agent")
  local ai = require("tasks_nvim.ai")

  local SECRET = string.rep("ab12", 16)

  -- ── the secret ─────────────────────────────────────────────────────────────
  local dir = H.tmpdir() .. "/ai-desktop-config"
  vim.fn.mkdir(dir, "p")
  local missing, why = agent.read_secret(dir)
  eq(missing, nil, "no file: no secret")
  has(why, "no control.secret")
  H.write(dir .. "/control.secret", "not hex\n")
  eq(agent.read_secret(dir), nil, "not hex digits")
  H.write(dir .. "/control.secret", string.rep("a", 63) .. "\n")
  eq(agent.read_secret(dir), nil, "63 digits are not a secret")
  H.write(dir .. "/control.secret", string.rep("x", 5000))
  local big, big_why = agent.read_secret(dir)
  eq(big, nil, "too large")
  lacks(big_why, "xxxx", "the reason never holds the content")
  H.write(dir .. "/control.secret", SECRET:upper() .. "\r\n")
  eq(agent.read_secret(dir), SECRET, "64 hex digits, trimmed, lower case")

  -- ── answers ────────────────────────────────────────────────────────────────
  eq(
    agent.parse_response("HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\n{}"),
    { status = 201, body = "{}" }
  )
  eq(
    agent.parse_response(
      'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{"a"\r\n3\r\n:1}\r\n0\r\n\r\n'
    ),
    { status = 200, body = '{"a":1}' },
    "a chunked body"
  )
  eq(agent.parse_response("garbage"), nil)
  eq(agent.parse_response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"), nil)

  -- ── the body ───────────────────────────────────────────────────────────────
  -- The vault as vim.fs.normalize gives it: forward slashes on Windows (a backslash is part of a name elsewhere), no
  -- trailing slash.
  local windows = vim.fn.has("win32") == 1
  local body = agent.payload(
    { id = "lib.nvim/x", title = "X", area = "lib.nvim" },
    windows and "C:\\vault\\" or "/vault/",
    "# X\n",
    "run",
    "split-plan"
  )
  eq(body.source, "tasks.nvim")
  eq(body.task_id, "lib.nvim/x")
  eq(body.area, "lib.nvim")
  eq(body.vault, windows and "C:/vault" or "/vault", "the vault normalized")
  eq(body.mode, "run")
  eq(body.kind, "split-plan")
  eq(body.private, nil, "no class of the area: ai-desktop's own list decides")
  eq(agent.payload({ id = "a/b" }, "/v", "", "prefill", "handoff").title, "a/b", "no title: the id")

  -- ── discovery: hub.json with a living process ──────────────────────────────
  local saved_config = vim.env.AI_DESKTOP_CONFIG_DIR
  vim.env.AI_DESKTOP_CONFIG_DIR = dir
  local pid = vim.uv.os_getpid()
  local function hub(t)
    H.write(dir .. "/hub.json", vim.json.encode(t))
  end
  local discovered, derr = pcall(function()
    eq(ai.hub_record(), nil, "no hub.json")
    hub({ app = "ai-desktop", port = 8123, pid = pid, version = "1", instance = "abc" })
    eq(
      ai.hub_record(),
      { app = "ai-desktop", port = 8123, pid = pid, instance = "abc" },
      "a living process: running"
    )
    hub({ app = "ai-desktop", port = 70000, pid = pid, version = "1", instance = "abc" })
    eq(ai.hub_record(), nil, "a port out of range")
    hub({ app = "ai-desktop", port = 81.5, pid = pid, version = "1", instance = "abc" })
    eq(ai.hub_record(), nil, "a port that is no whole number")
    hub({ app = "rules-desktop", port = 8123, pid = pid, version = "1", instance = "abc" })
    eq(ai.hub_record(), nil, "another app's file")
  end)
  vim.env.AI_DESKTOP_CONFIG_DIR = saved_config
  ok(discovered, tostring(derr))

  -- ── a stand-in of ai-desktop on a port of its own ──────────────────────────
  -- `answer(req)` gives status and body (strings only: it runs in a callback of libuv).
  local function fake_desktop(answer)
    local server = vim.uv.new_tcp()
    server:bind("127.0.0.1", 0)
    local port = server:getsockname().port
    local seen = {}
    server:listen(16, function()
      local client = vim.uv.new_tcp()
      server:accept(client)
      local buf = ""
      client:read_start(function(_, data)
        if not data then
          client:close()
          return
        end
        buf = buf .. data
        local head_end = buf:find("\r\n\r\n", 1, true)
        if not head_end then
          return
        end
        local len = tonumber(buf:match("[Cc]ontent%-[Ll]ength: (%d+)")) or 0
        if #buf < head_end + 3 + len then
          return
        end
        local req = {
          line = buf:match("^[^\r]+"),
          head = buf:sub(1, head_end),
          body = buf:sub(head_end + 4, head_end + 3 + len),
        }
        seen[#seen + 1] = req
        local status, text = answer(req)
        client:write(
          ("HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"):format(
            status,
            #text,
            text
          ),
          function()
            client:close()
          end
        )
      end)
    end)
    return port, seen, function()
      server:close()
    end
  end

  local HEALTH = '{"status":"ready","app":"ai-desktop","version":"1","instance":"inst-1"}'
  local CREATED = '{"job_id":"0123456789abcdef","status":"prefilled","private":false}'
  local function standard(req)
    if req.line:match("^GET /health ") then
      return 200, HEALTH
    end
    return 201, CREATED
  end

  local function hand_over(port, payload, extra)
    local result, err, done = nil, nil, false
    local foreground = {}
    local deps = vim.tbl_extend("force", {
      record = { app = "ai-desktop", port = port, pid = 4242, instance = "inst-1" },
      config_dir = dir,
      allow_foreground = function(p)
        foreground[#foreground + 1] = p
        return true
      end,
    }, extra or {})
    agent.hand_over(payload, function(e, r)
      err, result, done = e, r, true
    end, deps)
    vim.wait(5000, function()
      return done
    end)
    ok(done, "the hand-over answered")
    return err, result, foreground
  end

  local task_body = agent.payload(
    { id = "lib.nvim/x", title = "X", area = "lib.nvim" },
    "/vault",
    "# X\n\n## Akzeptanz\n",
    "prefill",
    "handoff"
  )

  local port, seen, stop = fake_desktop(standard)
  local served, serr = pcall(function()
    local err, result, foreground = hand_over(port, task_body)
    eq(err, nil)
    eq(result, {
      job_id = "0123456789abcdef",
      status = "prefilled",
      private = false,
      note = nil,
      peer = { port = port, pid = 4242, instance = "inst-1" },
    })
    eq(#seen, 2, "health, then the job")
    has(seen[1].line, "GET /health HTTP/1.1")
    has(seen[2].line, "POST /jobs HTTP/1.1")
    has(seen[2].head, "Authorization: Bearer " .. SECRET, "the secret in the header")
    has(seen[2].head, "Content-Type: application/json")
    has(seen[2].head, "Host: 127.0.0.1:" .. port, "the host ai-desktop checks")
    lacks(seen[2].head:lower(), "origin:", "a program sends no Origin")
    lacks(seen[1].head, SECRET, "the health question carries no secret")
    local sent = vim.json.decode(seen[2].body)
    eq(sent.task_id, "lib.nvim/x")
    eq(sent.markdown, "# X\n\n## Akzeptanz\n")
    eq(foreground, { 4242 }, "the focus right goes to the pid of hub.json, before the job")

    -- Another program on the port (another instance): the secret is not sent.
    local before = #seen
    local err2 = hand_over(port, task_body, {
      record = { app = "ai-desktop", port = port, pid = 4242, instance = "other" },
    })
    has(err2, "not the ai-desktop of hub.json")
    eq(#seen, before + 1, "only the health question")

    -- A hub.json without an instance cannot prove which program is on the port: the secret is not sent either.
    before = #seen
    local err_noinst = hand_over(port, task_body, {
      record = { app = "ai-desktop", port = port, pid = 4242, instance = "" },
    })
    has(err_noinst, "not the ai-desktop of hub.json")
    eq(#seen, before + 1, "only the health question, no job with the secret")

    -- No secret file: nothing is sent.
    local saved = H.read(dir .. "/control.secret")
    os.remove(dir .. "/control.secret")
    before = #seen
    local err3 = hand_over(port, task_body)
    has(err3, "no control.secret")
    eq(#seen, before + 1, "only the health question")
    H.write(dir .. "/control.secret", saved)

    -- A bad mode never leaves.
    local bad = vim.deepcopy(task_body)
    bad.mode = "execute"
    has(hand_over(port, bad), "mode or kind")
  end)
  stop()
  ok(served, tostring(serr))

  -- ── after the hand-over: confirm_run and drop_job prove the ai-desktop again ─
  -- The question to the person may stay open for long; ai-desktop may restart meanwhile on another port and another
  -- program may listen on the old one. Every request with the secret proves the instance of the hand-over first.
  local JOB = "0123456789abcdef"
  local JOB_WAITS = '{"id":"0123456789abcdef","status":"needs_confirmation"}'
  local JOB_RUNS = '{"id":"0123456789abcdef","status":"running"}'
  local function job_desktop(job_body, delete_status)
    return fake_desktop(function(req)
      if req.line:match("^GET /health ") then
        return 200, HEALTH
      end
      if req.line:match("^GET /jobs/") then
        if not job_body then
          return 404, '{"error":{"message":"no such job"}}'
        end
        return 200, job_body
      end
      if req.line:match("^DELETE /jobs/") then
        return delete_status or 204, ""
      end
      if req.line:match("^POST /jobs/[%w]+/run ") then
        return 200, JOB_RUNS
      end
      return 500, "{}"
    end)
  end
  local function call(fn, peer, id, extra)
    local err, outcome, done = nil, nil, false
    fn(peer, id, function(e, o)
      err, outcome, done = e, o, true
    end, vim.tbl_extend("force", { config_dir = dir }, extra or {}))
    vim.wait(5000, function()
      return done
    end)
    ok(done, "answered")
    return err, outcome
  end
  local function lines(reqs)
    return vim.tbl_map(function(r)
      return r.line
    end, reqs)
  end

  -- The hand-over says which ai-desktop took the job.
  local hp, _, hstop = fake_desktop(standard)
  local _, handed_res = hand_over(hp, task_body)
  hstop()
  eq(handed_res.peer, { port = hp, pid = 4242, instance = "inst-1" }, "the proved ai-desktop")

  -- A job that still waits: health, where the job is (no secret), then DELETE with the secret.
  local p1, seen1, stop1 = job_desktop(JOB_WAITS)
  local drop_err, outcome = call(agent.drop_job, { port = p1, instance = "inst-1" }, JOB)
  stop1()
  eq(drop_err, nil)
  eq(outcome, "dropped")
  eq(lines(seen1), {
    "GET /health HTTP/1.1",
    "GET /jobs/" .. JOB .. " HTTP/1.1",
    "DELETE /jobs/" .. JOB .. " HTTP/1.1",
  })
  lacks(seen1[1].head, SECRET, "the health question carries no secret")
  lacks(seen1[2].head, SECRET, "the job question carries no secret")
  has(seen1[3].head, "Authorization: Bearer " .. SECRET, "the secret goes with the DELETE")

  -- Confirmed in the dashboard meanwhile: DELETE would cancel the running job; it is left, and the status is said.
  local p2, seen2, stop2 = job_desktop(JOB_RUNS)
  drop_err, outcome = call(agent.drop_job, { port = p2, instance = "inst-1" }, JOB)
  stop2()
  eq(drop_err, nil)
  eq(outcome, "running", "the status of the job confirmed in the dashboard")
  eq(#seen2, 2, "no DELETE of a running job")

  -- ai-desktop does not know the job any more (restarted: its jobs live in memory).
  local p3, seen3, stop3 = job_desktop(nil)
  drop_err, outcome = call(agent.drop_job, { port = p3, instance = "inst-1" }, JOB)
  stop3()
  eq({ drop_err, outcome }, { nil, "gone" })
  eq(#seen3, 2, "no DELETE of a job that is gone")

  -- ai-desktop refuses the DELETE: said.
  local p4, _, stop4 = job_desktop(JOB_WAITS, 403)
  drop_err = call(agent.drop_job, { port = p4, instance = "inst-1" }, JOB)
  stop4()
  has(drop_err, "did not put the job away (403)")

  -- Another program on the old port (ai-desktop restarted elsewhere): it answers everything with 404, as the old
  -- drop_job took for "put away". It is not asked about the job, and the secret never reaches it.
  local stranger = function()
    return 404, '{"error":{"message":"not found"}}'
  end
  local p5, seen5, stop5 = fake_desktop(stranger)
  drop_err, outcome = call(agent.drop_job, { port = p5, instance = "inst-1" }, JOB)
  local cerr = call(agent.confirm_run, { port = p5, instance = "inst-1" }, JOB)
  stop5()
  has(drop_err, "not the ai-desktop that took the job; nothing was sent")
  eq(outcome, nil)
  has(cerr, "not the ai-desktop that took the job; nothing was sent")
  eq(lines(seen5), { "GET /health HTTP/1.1", "GET /health HTTP/1.1" }, "only the health questions")
  for _, req in ipairs(seen5) do
    lacks(req.head, SECRET, "the stranger never gets the secret")
  end

  -- Another ai-desktop (a new instance) on the old port does not get the secret either.
  local p6, seen6, stop6 = job_desktop(JOB_WAITS)
  drop_err = call(agent.drop_job, { port = p6, instance = "inst-0" }, JOB)
  cerr = call(agent.confirm_run, { port = p6, instance = "inst-0" }, JOB)
  stop6()
  has(drop_err, "not the ai-desktop that took the job")
  has(cerr, "not the ai-desktop that took the job")
  eq(#seen6, 2, "only the health questions")

  -- confirm_run: health, then the run with the secret.
  local p7, seen7, stop7 = job_desktop(JOB_WAITS)
  cerr = call(agent.confirm_run, { port = p7, instance = "inst-1" }, JOB)
  stop7()
  eq(cerr, nil)
  eq(lines(seen7), { "GET /health HTTP/1.1", "POST /jobs/" .. JOB .. "/run HTTP/1.1" })
  has(seen7[2].head, "Authorization: Bearer " .. SECRET)
  eq(vim.json.decode(seen7[2].body), { confirm_private = true })

  -- Nobody on the port, an id that is not plain, no secret file: nothing with the secret leaves.
  local gone = vim.uv.new_tcp()
  gone:bind("127.0.0.1", 0)
  local gone_port = gone:getsockname().port
  gone:close()
  has(call(agent.drop_job, { port = gone_port, instance = "inst-1" }, JOB), "does not answer")
  local p8, seen8, stop8 = job_desktop(JOB_WAITS)
  for _, bad in ipairs({ "../health", "a b", "", "a?x=1" }) do
    has(call(agent.drop_job, { port = p8, instance = "inst-1" }, bad), "not plain", bad)
    has(call(agent.confirm_run, { port = p8, instance = "inst-1" }, bad), "not plain", bad)
  end
  eq(#seen8, 0, "an id that is not plain is never put into a request line")
  local saved_secret = H.read(dir .. "/control.secret")
  os.remove(dir .. "/control.secret")
  has(call(agent.drop_job, { port = p8, instance = "inst-1" }, JOB), "no control.secret")
  H.write(dir .. "/control.secret", saved_secret)
  stop8()
  eq(lines(seen8), { "GET /health HTTP/1.1" }, "without the secret only the health question")

  -- ai-desktop refuses: its message is said, the secret is not.
  local refusing_port, _, stop_refusing = fake_desktop(function(req)
    if req.line:match("^GET /health ") then
      return 200, HEALTH
    end
    return 401, '{"error":{"message":"the control secret of ai-desktop is required"}}'
  end)
  local refused = hand_over(refusing_port, task_body)
  stop_refusing()
  has(refused, "refused the task (401): the control secret of ai-desktop is required")
  lacks(refused, SECRET)

  -- Nobody on the port.
  local closed = vim.uv.new_tcp()
  closed:bind("127.0.0.1", 0)
  local closed_port = closed:getsockname().port
  closed:close()
  has(hand_over(closed_port, task_body), "does not answer")
  -- A connect libuv refuses at once is said at once, not after the 5 s of the timer.
  local t0 = vim.uv.hrtime()
  has(hand_over(0, task_body), "cannot connect to 127.0.0.1:0")
  ok((vim.uv.hrtime() - t0) / 1e9 < 2, "said at once")

  -- A watched job comes back with its task file (up to 256 KiB) and its output (up to 512 KiB): an answer far larger
  -- than one of the small routes is still read whole.
  local big_markdown = ("x"):rep(200 * 1024)
  local big_output = ("y"):rep(300 * 1024)
  local job_port, job_seen, stop_job = fake_desktop(function(req)
    if req.line:match("^GET /jobs/0123456789abcdef ") then
      return 200,
        vim.json.encode({
          id = "0123456789abcdef",
          status = "done",
          markdown = big_markdown,
          output = big_output,
        })
    end
    return 404, '{"error":{"message":"no such route"}}'
  end)
  local watched, watch_err, watch_done = nil, nil, false
  agent.watch(job_port, "0123456789abcdef", function(e, job)
    watch_err, watched, watch_done = e, job, true
  end, { interval_ms = 50, config_dir = dir })
  vim.wait(5000, function()
    return watch_done
  end)
  stop_job()
  ok(watch_done, "the watch ended")
  -- ai-desktop reads a job only with the control secret (the login of its management API).
  has(
    job_seen[1] and job_seen[1].head or "",
    "Authorization: Bearer " .. SECRET,
    "the watch sends the secret"
  )
  eq(watch_err, nil, "a large job is no broken answer")
  eq(watched and #watched.output, #big_output, "the whole output")
  eq(watched and #watched.markdown, #big_markdown, "the whole task file")
  -- Something larger than any job of ai-desktop is still refused.
  local huge_port, _, stop_huge = fake_desktop(function()
    return 200, ("z"):rep(9 * 1024 * 1024)
  end)
  local huge_err, huge_done = nil, false
  agent.request(huge_port, "GET", "/jobs/x", {}, "", function(e)
    huge_err, huge_done = e, true
  end, agent.MAX_JOB_RESPONSE)
  vim.wait(5000, function()
    return huge_done
  end)
  stop_huge()
  has(huge_err or "", "larger than an answer of ai-desktop")

  -- ── :Tasks agent ───────────────────────────────────────────────────────────
  local cmd = require("tasks_nvim.ui.cmd")
  local root = F.vault(H)
  F.task(
    H,
    root,
    "lib.nvim",
    "agent-me",
    F.meta("Agent me", "open", {}),
    "\n## Akzeptanz\n\n- [ ] it\n"
  )
  require("tasks_nvim.vault").set_root(root)
  local told = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    told[#told + 1] = { msg = msg, level = level }
  end
  local saved_ai = package.loaded["ai"]
  local function last()
    return told[#told] and told[#told].msg or ""
  end
  local ran, rerr = pcall(function()
    local handed
    local on = { on = true, setting = "auto" }
    local running = { installed = true, running = true }
    local function stub(payload, cb)
      handed = payload
      cb(nil, { job_id = "0123456789abcdef", status = "needs_confirmation", private = true })
    end
    cmd.task_agent(
      { args = { id = "lib.nvim/agent-me" }, kv = {}, flags = {}, rest = {} },
      { state = on, ai_desktop = running, hand_over = stub }
    )
    eq(handed.task_id, "lib.nvim/agent-me")
    eq(handed.mode, "prefill", "prefill unless said")
    eq(handed.kind, "handoff", "handoff unless said")
    eq(handed.title, "Agent me")
    has(handed.markdown, "## Akzeptanz", "the task file as it is")
    has(last(), "job 0123456789abcdef")
    has(last(), "asks first")

    -- From the task's buffer, with mode and kind.
    vim.cmd.edit(vim.fn.fnameescape(root .. "/lib.nvim/ROADMAP/tasks/agent-me.md"))
    cmd.task_agent(
      { args = {}, kv = { mode = "run", kind = "review-done" }, flags = {}, rest = {} },
      { state = on, ai_desktop = running, hand_over = stub }
    )
    eq(handed.mode, "run")
    eq(handed.kind, "review-done")

    handed = nil
    cmd.task_agent(
      { args = { id = "lib.nvim/agent-me" }, kv = { mode = "now" }, flags = {}, rest = {} },
      { state = on, ai_desktop = running, hand_over = stub }
    )
    eq(handed, nil, "a bad mode is refused here")
    has(last(), "mode is prefill or run")

    cmd.task_agent(
      { args = { id = "lib.nvim/agent-me" }, kv = {}, flags = {}, rest = {} },
      { state = { on = false, setting = false }, ai_desktop = running, hand_over = stub }
    )
    has(last(), "the AI functions are off")
    eq(handed, nil, "off: nothing is handed over")

    cmd.task_agent(
      { args = { id = "lib.nvim/no-such" }, kv = {}, flags = {}, rest = {} },
      { state = on, ai_desktop = running, hand_over = stub }
    )
    has(last(), "no-such")

    -- The error of the hand-over is said.
    cmd.task_agent({ args = { id = "lib.nvim/agent-me" }, kv = {}, flags = {}, rest = {} }, {
      state = on,
      ai_desktop = running,
      hand_over = function(_, cb)
        cb("ai-desktop does not answer: x", nil)
      end,
    })
    has(last(), "agent: ai-desktop does not answer")

    -- No ai-desktop and no ai.nvim.
    package.loaded["ai"] = nil
    local saved_path = package.path
    package.path = ""
    cmd.task_agent(
      { args = { id = "lib.nvim/agent-me" }, kv = {}, flags = {}, rest = {} },
      { state = on, ai_desktop = { installed = true, running = false } }
    )
    package.path = saved_path
    has(last(), "installed but not running: start it")

    -- ai.nvim answers once instead (a stand-in).
    local asked
    package.loaded["ai"] = {
      setup = function() end,
      ask = function(req, cb)
        asked = req
        cb(true, { text = "the plan of the stand-in" })
      end,
    }
    told = {}
    cmd.task_agent(
      { args = { id = "lib.nvim/agent-me" }, kv = { mode = "run" }, flags = {}, rest = {} },
      {
        state = on,
        ai_desktop = { installed = false, running = false },
        confirm = function(_, _, cb)
          cb(true)
        end,
      }
    )
    vim.wait(1000, function()
      return last():find("answered", 1, true) ~= nil
    end)
    has(told[1].msg, "ai.nvim answers once instead", "the fallback says so")
    has(asked.prompt, "## Akzeptanz")
    eq(vim.api.nvim_buf_get_name(0):match("tasks://agent/.*$"), "tasks://agent/lib.nvim/agent-me")
    has(
      table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
      "the plan of the stand-in",
      "the answer below the prompt"
    )

    -- prefill with ai.nvim: the prompt waits in the buffer, nothing is asked.
    asked = nil
    cmd.task_agent(
      { args = { id = "lib.nvim/agent-me" }, kv = {}, flags = {}, rest = {} },
      { state = on, ai_desktop = { installed = false, running = false } }
    )
    eq(asked, nil, "prefill sends nothing")
    has(last(), "mode=run sends it")

    -- No message ever holds the secret.
    for _, t in ipairs(told) do
      lacks(t.msg, SECRET)
    end
  end)
  vim.notify = orig_notify
  package.loaded["ai"] = saved_ai
  pcall(vim.cmd, "silent! %bwipeout!")
  ok(ran, tostring(rerr))

  -- ── the route: values to complete, hidden while the AI functions are off ───
  local route
  for _, r in ipairs(require("tasks_nvim.ui.routes").routes({ flat = true })) do
    if table.concat(r.path, " ") == "agent" then
      route = r
    end
  end
  ok(route, ":Tasks agent is a route")
  eq(route.kv[1].values, { "prefill", "run" })
  eq(route.kv[2].values, agent.KINDS, "the kinds of ai-desktop")
  ok(type(route.available) == "function", "it can hide itself")
  local config = require("tasks_nvim.config")
  local before = vim.deepcopy(config.get())
  config.merge({ ai = false })
  eq(route.available(), false, "ai = false: out of <Tab>")
  config.merge({ ai = true })
  eq(route.available(), true, "ai = true: offered")
  config.merge({ ai = before.ai })
end
