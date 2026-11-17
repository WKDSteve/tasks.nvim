-- TESTS/tasks_agent_brief_spec.lua -- `agent-brief`: the tasks-family brief for AI agents (tasks_nvim.agent_brief).

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local cli = require("tasks_nvim.cli")
  local brief = require("tasks_nvim.agent_brief")
  local contract = require("tasks_nvim.contract")
  local model = require("tasks_nvim.model")

  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(argv)
    local out, err = {}, {}
    local code = cli.run(argv, {
      out = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    return { code = code, out = table.concat(out), err = table.concat(err) }
  end

  -- ── Markdown: no vault needed, versions on top ─────────────────────────
  local r = run({ "agent-brief" })
  eq(r.code, 0, "agent-brief runs without a vault: " .. r.err)
  has(r.out, "# Tasks family: working on a task vault")
  has(r.out, ("brief_version: %d"):format(brief.BRIEF_VERSION))
  has(r.out, ("contract_schema: %d"):format(contract.SCHEMA), "names the contract version")
  has(r.out, contract.ENGINE_VERSION, "names the engine version")

  -- the workflow uses the default claim name of ai-desktop in every example
  has(r.out, "tasks claim <id> --by=ai-desktop:<job>")
  has(r.out, "tasks done <id> --commits=repo@sha,...")
  has(r.out, "--by=ai-desktop:<job>`. It frees the claim.")
  has(r.out, "tasks unclaim <id> --by=ai-desktop:<job>")
  has(r.out, "never pass it with `--force`", "a foreign claim is a stop, not a force")

  -- every allowed value comes from the model, so the brief and the engine never disagree
  for _, list in ipairs({
    model.KINDS,
    model.STATUSES,
    model.EFFORTS,
    model.ACTORS,
    model.CATEGORIES,
    model.SCOPES,
  }) do
    for _, word in ipairs(list) do
      has(r.out, "`" .. word .. "`", "allowed value " .. word)
    end
  end

  -- the command reference is the CLI's own usage text, in one fenced block
  local help = run({ "--help" })
  eq(help.code, 0)
  has(r.out, "```text\n" .. help.out:gsub("\n+$", "") .. "\n```", "the usage text verbatim")
  has(help.out, "agent-brief [--format=md|json]", "--help lists the command")
  local _, fences = r.out:gsub("```", "")
  eq(fences, 2, "exactly one fenced block (the usage has no fence of its own)")

  -- ── --by: the claim name of the examples ───────────────────────────────
  r = run({ "agent-brief", "--by=ai-desktop:job-42" })
  eq(r.code, 0)
  has(r.out, "tasks claim <id> --by=ai-desktop:job-42")
  lacks(r.out, "--by=ai-desktop:<job>", "the default is replaced in every example")

  for _, bad in ipairs({ "--by=", "--by=two words", "--by=a\tb", "--by=" .. string.rep("x", 81) }) do
    r = run({ "agent-brief", bad })
    eq(r.code, 2, "refused: " .. bad)
    has(r.err, "--by must be")
  end
  ok(brief.check_by(string.rep("x", 80)), "80 characters are fine")

  -- ── usage errors ───────────────────────────────────────────────────────
  r = run({ "agent-brief", "--format=yaml" })
  eq(r.code, 2)
  has(r.err, "--format must be md or json")
  r = run({ "agent-brief", "extra" })
  eq(r.code, 2)
  has(r.err, "takes no positional argument")

  -- ── JSON: versions for the caller to compare, the Markdown inside ──────
  r = run({ "agent-brief", "--format=json" })
  eq(r.code, 0)
  local doc = vim.json.decode(r.out)
  eq(doc.schema, "tasks-agent-brief/1")
  eq(doc.brief_version, brief.BRIEF_VERSION)
  eq(doc.contract_schema, contract.SCHEMA)
  eq(doc.engine_version, contract.ENGINE_VERSION)
  eq(doc.plugin, contract.PLUGIN)
  eq(doc.by, "ai-desktop:<job>")
  eq(doc.markdown, run({ "agent-brief" }).out, "the same Markdown as --format=md")
  eq(run({ "agent-brief", "--format=json" }).out, r.out, "byte for byte the same on a second run")
  has(r.out, '{"brief_version":', "canonical key order (sorted)")
end
