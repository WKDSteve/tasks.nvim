-- TESTS/tasks_sort_dates_spec.lua -- `--sort=` by date and by title, for the order dropdown of tasks-desktop:
-- newest and oldest first by created and updated, the next reminder, the title. A task without the date comes
-- last in both directions, and a tie keeps the default order.

return function(H)
  local eq, ok = H.eq, H.ok
  local model = require("tasks_nvim.model")

  ---@param slug string
  ---@param fields table
  ---@return table
  local function task(slug, fields)
    return vim.tbl_extend("force", {
      id = "a/" .. slug,
      area = "a",
      slug = slug,
      path = slug .. ".md",
      title = slug,
      status = "open",
    }, fields)
  end

  ---@param order string
  ---@param tasks table[]
  ---@return string
  local function order_of(order, tasks)
    local parsed, err = model.parse_sort(order)
    eq(parsed, order, "the word is known: " .. tostring(err))
    return table.concat(
      vim.tbl_map(function(t)
        return t.slug
      end, model.sort(vim.list_slice(tasks, 1), order)),
      " "
    )
  end

  local dated = {
    task("none", {}),
    task("old", { created = "2026-01-01", updated = "2026-03-01", remind = "2026-05-01" }),
    task("new", { created = "2026-02-01", updated = "2026-02-02", remind = "2026-04-01" }),
    task("tie-b", { created = "2026-01-15", updated = "2026-02-15", remind = "2026-04-15" }),
    task("tie-a", { created = "2026-01-15", updated = "2026-02-15", remind = "2026-04-15" }),
    task("broken", { created = "soon", updated = "soon", remind = "soon" }),
  }

  eq(order_of("created-desc", dated), "new tie-a tie-b old broken none", "created-desc")
  eq(order_of("created-asc", dated), "old tie-a tie-b new broken none", "created-asc")
  eq(order_of("updated-desc", dated), "old tie-a tie-b new broken none", "updated-desc")
  eq(order_of("updated-asc", dated), "new tie-a tie-b old broken none", "updated-asc")
  eq(order_of("remind", dated), "new tie-a tie-b old broken none", "remind: next first")

  eq(
    order_of("title", {
      task("c", { title = "beta" }),
      task("b", { title = "Alpha" }),
      task("a", { title = "alpha" }),
      task("d", { title = "Zeta" }),
    }),
    "a b c d",
    "title: regardless of case, a tie in the default order"
  )

  -- ── the words reach every place that lists them ──
  local words = { "created-desc", "created-asc", "updated-desc", "updated-asc", "remind", "title" }
  for _, word in ipairs(words) do
    ok(vim.tbl_contains(model.SORTS, word), "model.SORTS: " .. word)
  end

  local here = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
  local schema =
    vim.json.decode(H.read(here .. "../schemas/tasks-export/1/tasks-export.schema.json"))
  local enum
  for _, def in pairs(schema["$defs"]) do
    local props = type(def) == "table" and def.properties or nil
    if props and props.kind and props.kind.const == "tasks.order" then
      enum = props.sort and props.sort.enum
    end
  end
  eq(
    table.concat(enum or {}, " "),
    table.concat(model.SORTS, " "),
    "the schema's enum is model.SORTS"
  )

  local types = H.read(here .. "../schemas/tasks-export/1/tasks-export.d.ts")
  local contract = H.read(here .. "../docs/CONTRACT.md")
  local commands = H.read(here .. "../docs/COMMANDS.md")
  local help = H.read(here .. "../lua/tasks_nvim/cli.lua")
  for _, word in ipairs(words) do
    ok(types:find('"' .. word .. '"', 1, true) ~= nil, "tasks-export.d.ts: " .. word)
    ok(contract:find("`" .. word .. "`", 1, true) ~= nil, "docs/CONTRACT.md: " .. word)
    ok(commands:find("`" .. word .. "`", 1, true) ~= nil, "docs/COMMANDS.md: " .. word)
    ok(help:find(word, 1, true) ~= nil, "cli help: " .. word)
  end
end
