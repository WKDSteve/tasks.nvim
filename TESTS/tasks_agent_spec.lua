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
    eq(result, { job_id = "0123456789abcdef", status = "prefilled", private = false, note = nil })
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
