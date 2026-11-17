-- TESTS/tasks_ai_spec.lua -- the option `ai` (false | true | "auto") and what `tasks_nvim.ai` finds of the ai family.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local config = require("tasks_nvim.config")
  local ai = require("tasks_nvim.ai")

  -- The option: `auto` by default; true, false and "auto" pass, anything else is reported and the default stays.
  eq(require("tasks_nvim.config.DEFAULTS").ai, "auto", "the default is auto")
  eq(config.validate({ ai = false }).ai, false, "false passes")
  eq(config.validate({ ai = true }).ai, true, "true passes")
  eq(config.validate({ ai = "auto" }).ai, "auto", "auto passes")
  eq(config.validate({ ai = "yes" }).ai, nil, "another word is dropped")
  eq(config.validate({ ai = 1 }).ai, nil, "a number is dropped")

  -- A machine of the test's own: the family folder and the config folder of ai-desktop are two empty folders.
  local saved_env = {
    family = vim.env.APPKIT_FAMILY_DIR,
    config = vim.env.AI_DESKTOP_CONFIG_DIR,
  }
  local saved_ai = package.loaded["ai"]
  local before = vim.deepcopy(config.get())
  local family = H.tmpdir() .. "/family"
  local desktop = H.tmpdir() .. "/ai-desktop-config"
  vim.fn.mkdir(family .. "/installed", "p")
  vim.fn.mkdir(desktop, "p")
  vim.env.APPKIT_FAMILY_DIR = family
  vim.env.AI_DESKTOP_CONFIG_DIR = desktop
  local manifest = family .. "/installed/ai-desktop.json"
  local record = desktop .. "/hub.json"
  local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local program = H.tmpdir() .. "/ai-desktop.exe"
  write(program, "")

  local done, err = pcall(function()
    eq(ai.family_dir(), family, "$APPKIT_FAMILY_DIR names the family folder")
    eq(ai.config_dir(), desktop, "$AI_DESKTOP_CONFIG_DIR names the config folder of ai-desktop")

    -- A module `ai` of another plugin (no `setup`) is not ai.nvim.
    package.loaded["ai"] = {}
    eq(ai.ai_nvim(), false, "a module ai without setup is not ai.nvim")
    eq(
      ai.ai_desktop(),
      { installed = false, running = false },
      "no manifest, no hub.json: not found"
    )
    local nothing = ai.state("auto")
    eq(nothing.on, false, "auto with nothing found: not offered")

    -- Installed: a manifest whose program is there.
    write(
      manifest,
      vim.json.encode({
        schema = "appkit-installed/1",
        app = "ai-desktop",
        program = program,
        env_prefix = "AI_DESKTOP",
      })
    )
    eq(ai.ai_desktop().installed, true, "a manifest with its program: installed")
    eq(ai.state("auto").on, true, "auto with ai-desktop installed: offered")
    write(
      manifest,
      "\239\187\191"
        .. vim.json.encode({
          schema = "appkit-installed/1",
          app = "ai-desktop",
          program = program,
          env_prefix = "AI_DESKTOP",
        })
    )
    eq(ai.ai_desktop().installed, true, "a manifest with a byte order mark is read")
    write(
      manifest,
      vim.json.encode({
        schema = "appkit-installed/1",
        app = "ai-desktop",
        program = H.tmpdir() .. "/gone.exe",
        env_prefix = "AI_DESKTOP",
      })
    )
    eq(ai.ai_desktop().installed, false, "a manifest whose program is gone is a leftover")
    write(
      manifest,
      vim.json.encode({
        schema = "appkit-installed/9",
        app = "ai-desktop",
        program = program,
        env_prefix = "AI_DESKTOP",
      })
    )
    eq(ai.ai_desktop().installed, false, "a manifest of another schema does not count")
    write(manifest, "{ not json")
    eq(ai.ai_desktop().installed, false, "a manifest that is no JSON does not count")
    write(manifest, string.rep(" ", 5000) .. "{}")
    eq(ai.ai_desktop().installed, false, "a manifest above 4 KiB is not read")
    os.remove(manifest)

    -- Running: a hub.json of ai-desktop whose process is alive (this Neovim stands in for it).
    local me = vim.uv.os_getpid()
    write(
      record,
      vim.json.encode({ app = "ai-desktop", port = 17700, pid = me, version = "1", instance = "x" })
    )
    eq(
      ai.ai_desktop(),
      { installed = false, running = true },
      "a hub.json of a live process: running"
    )
    eq(ai.state("auto").on, true, "auto with ai-desktop running: offered")
    write(
      record,
      vim.json.encode({
        app = "ai-desktop",
        port = 17700,
        pid = 2147483646,
        version = "1",
        instance = "x",
      })
    )
    eq(ai.ai_desktop().running, false, "a hub.json whose process is gone is stale")
    write(
      record,
      vim.json.encode({
        app = "tasks-desktop",
        port = 17700,
        pid = me,
        version = "1",
        instance = "x",
      })
    )
    eq(ai.ai_desktop().running, false, "a hub.json of another app does not count")
    write(
      record,
      vim.json.encode({ app = "ai-desktop", port = 0, pid = me, version = "1", instance = "x" })
    )
    eq(ai.ai_desktop().running, false, "a hub.json without a port does not count")
    os.remove(record)

    -- ai.nvim alone is enough for auto.
    package.loaded["ai"] = { setup = function() end }
    eq(ai.ai_nvim(), true, "a module ai with setup is ai.nvim")
    eq(ai.state("auto").on, true, "auto with ai.nvim: offered")
    eq(
      ai.state("auto").ai_desktop,
      { installed = false, running = false },
      "auto looked for ai-desktop too"
    )

    -- false and true decide alone: nothing is looked for.
    local off = ai.state(false)
    eq(off.on, false, "false: not offered although ai.nvim is there")
    eq(off.ai_nvim, nil, "false: ai.nvim was not looked for")
    eq(off.ai_desktop, nil, "false: ai-desktop was not looked for")
    package.loaded["ai"] = {}
    local on = ai.state(true)
    eq(on.on, true, "true: offered although nothing is found")
    eq(on.ai_desktop, nil, "true: nothing was looked for")
    eq(
      ai.state(false, true).ai_desktop,
      { installed = false, running = false },
      "look = true looks anyway"
    )

    -- enabled() follows setup().
    config.merge({ ai = false })
    package.loaded["ai"] = { setup = function() end }
    eq(ai.enabled(), false, "setup({ ai = false }) turns the AI functions off")
    config.merge({ ai = "auto" })
    eq(ai.enabled(), true, "setup({ ai = 'auto' }) with ai.nvim: on")
    config.merge({})
    eq(config.get().ai, "auto", "a setup without ai is back at auto")

    -- :checkhealth names the setting and what is found.
    local lines = {}
    local function say(kind)
      return function(msg)
        lines[#lines + 1] = kind .. ": " .. msg
      end
    end
    config.merge({ ai = false })
    require("tasks_nvim.health").check_ai(say("start"), say("ok"), say("info"))
    has(table.concat(lines, "\n"), "start: tasks.nvim: AI functions", "a section of its own")
    has(
      table.concat(lines, "\n"),
      "info: ai = false: not offered -- found: ai.nvim",
      "off, and what is there"
    )
    lines = {}
    config.merge({ ai = "auto" })
    package.loaded["ai"] = {}
    write(
      record,
      vim.json.encode({ app = "ai-desktop", port = 17700, pid = me, version = "1", instance = "x" })
    )
    require("tasks_nvim.health").check_ai(say("start"), say("ok"), say("info"))
    has(
      table.concat(lines, "\n"),
      'ok: ai = "auto": offered -- found: ai-desktop (running)',
      "auto, found running"
    )
    os.remove(record)
    lines = {}
    require("tasks_nvim.health").check_ai(say("start"), say("ok"), say("info"))
    has(
      table.concat(lines, "\n"),
      'info: ai = "auto": not offered -- found: neither ai.nvim nor ai-desktop',
      "auto, nothing found"
    )
  end)

  package.loaded["ai"] = saved_ai
  vim.env.APPKIT_FAMILY_DIR = saved_env.family
  vim.env.AI_DESKTOP_CONFIG_DIR = saved_env.config
  config.merge(before)
  ok(done, "the ai spec ran through: " .. tostring(err))
end
