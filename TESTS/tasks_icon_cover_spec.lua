-- TESTS/tasks_icon_cover_spec.lua -- the fields `icon` (an emoji, a file below assets/ or a word) and `cover` (a picture
-- below assets/): the one reader `model.icon_of`, and how tasks, plans, projects, paths and meetings read them.

---@diagnostic disable: need-check-nil, param-type-mismatch
-- Why: a value is bound with assert()/ok() in the same body, so a nil fails the spec at that line.

return function(H)
  local eq, ok = H.eq, H.ok
  local model = require("tasks_nvim.model")
  local plans = require("tasks_nvim.plans")
  local meetings = require("tasks_nvim.meetings")

  ---UTF-8 of code points (the spec file stays ASCII: an editor or a tool never changes an invisible joiner).
  ---@param ... integer
  ---@return string
  local function u(...)
    local out = {}
    for _, cp in ipairs({ ... }) do
      if cp < 0x80 then
        out[#out + 1] = string.char(cp)
      elseif cp < 0x800 then
        out[#out + 1] = string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
      elseif cp < 0x10000 then
        out[#out + 1] =
          string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
      else
        out[#out + 1] = string.char(
          0xF0 + math.floor(cp / 262144),
          0x80 + math.floor(cp / 4096) % 64,
          0x80 + math.floor(cp / 64) % 64,
          0x80 + cp % 64
        )
      end
    end
    return table.concat(out)
  end

  local CRAB = u(0x1F980)
  local BOOK = u(0x1F4D6)
  local FAMILY = u(0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467) -- three people joined by ZWJ
  local WAVE_DARK = u(0x1F44B, 0x1F3FF) -- a skin tone
  local HEART = u(0x2764, 0xFE0F) -- a text symbol with the emoji selector
  local FLAG_DE = u(0x1F1E9, 0x1F1EA) -- two regional indicators
  local FLAG_SCOTLAND = u(0x1F3F4, 0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F)
  local KEYCAP_1 = u(0x31, 0xFE0F, 0x20E3)
  local TECHNOLOGIST = u(0x1F9D1, 0x1F3FD, 0x200D, 0x1F4BB)

  -- ── one emoji: one grapheme cluster of an emoji sequence ──────────────────
  for name, e in pairs({
    crab = CRAB,
    book = BOOK,
    family = FAMILY,
    wave = WAVE_DARK,
    heart = HEART,
    flag = FLAG_DE,
    scotland = FLAG_SCOTLAND,
    keycap = KEYCAP_1,
    technologist = TECHNOLOGIST,
  }) do
    ok(model.is_emoji(e), "one emoji: " .. name)
  end
  ok(not model.is_emoji(CRAB .. CRAB), "two emoji are not one")
  ok(not model.is_emoji(CRAB .. " "), "an emoji with a blank")
  ok(not model.is_emoji(CRAB .. "a"), "an emoji with a letter")
  ok(not model.is_emoji("a"), "a letter")
  ok(not model.is_emoji(u(0xE4)), "a letter with an umlaut")
  ok(not model.is_emoji("1"), "a digit without the keycap")
  ok(not model.is_emoji(u(0x1F1E9)), "one regional indicator")
  ok(not model.is_emoji(u(0x1F1E9, 0x1F1EA, 0x1F1E9)), "three regional indicators")
  ok(not model.is_emoji(u(0x1F468, 0x200D)), "a joiner at the end")
  ok(not model.is_emoji(u(0x200D, 0x1F468)), "a joiner at the start")
  ok(not model.is_emoji(u(0x1F3F4, 0xE0067, 0xE0062)), "a tag sequence without its end")
  ok(not model.is_emoji("\240\159\166"), "cut UTF-8")
  ok(not model.is_emoji("\192\128"), "overlong UTF-8")
  ok(not model.is_emoji("\237\160\128"), "a surrogate")
  ok(not model.is_emoji(""), "empty")
  ok(not model.is_emoji(string.rep(CRAB .. u(0x200D), 60) .. CRAB), "longer than the limit")
  ok(not model.is_emoji(5), "a number")

  -- ── icon_of: the three forms, normed to { kind, value } ───────────────────
  eq(model.icon_of(CRAB), { kind = "emoji", value = CRAB })
  eq(model.icon_of(FAMILY), { kind = "emoji", value = FAMILY })
  eq(model.icon_of("assets/icon.svg"), { kind = "asset", value = "assets/icon.svg" })
  eq(model.icon_of("assets/images/Icon.PNG"), { kind = "asset", value = "assets/images/Icon.PNG" })
  eq(model.icon_of("handshake"), { kind = "word", value = "handshake" })
  for _, w in ipairs(meetings.ICONS) do
    eq(model.icon_of(w), { kind = "word", value = w }, "every meeting icon is a word: " .. w)
  end
  local function err(v)
    local icon, e = model.icon_of(v)
    eq(icon, nil, "no icon: " .. tostring(v))
    return e or ""
  end
  ok(err("rocket"):find("unknown icon 'rocket'", 1, true), "a word not in the list")
  ok(err("assets/../x.svg"):find("below assets/", 1, true), "no ..")
  ok(err("assets/x.gif"):find("no image", 1, true), "gif is no image type here")
  ok(err("assets/x"):find("no image", 1, true), "no extension")
  ok(err("assets/a b.png"):find("below assets/", 1, true), "no blank")
  ok(err("assets/a\\b.png"):find("below assets/", 1, true), "no backslash")
  ok(err("assets//x.png"):find("below assets/", 1, true), "no empty segment")
  ok(err("C:/x.png"):find("neither one emoji", 1, true), "an absolute path")
  ok(err("images/x.png"):find("neither one emoji", 1, true), "a path not below assets/")
  ok(err(CRAB .. CRAB):find("neither one emoji", 1, true), "two emoji")
  ok(err("Ab"):find("unknown icon", 1, true), "a word in another case")
  err("")
  err(5)
  eq(model.asset_error("assets/cover.webp", "cover"), nil)
  eq(model.asset_error("assets/cover.jpeg", "cover"), nil)
  ok(model.asset_error("assets/" .. string.rep("a", 200) .. ".png", "cover"), "too long")

  -- ── a task reads both; without them it reads as before ────────────────────
  local function task(lines)
    return model.parse_text(
      "---\n" .. table.concat(lines, "\n") .. "\n---\nBody.\n",
      { path = "/v/lib.nvim/ROADMAP/tasks/t.md", area = "lib.nvim" }
    )
  end
  local plain = task({ "title: T", "status: open" })
  ok(plain.valid, "a plain task is valid")
  eq(plain.icon, nil)
  eq(plain.cover, nil)
  local t = task({ "title: T", "status: open", "icon: " .. CRAB, "cover: assets/cover.png" })
  ok(t.valid, "icon and cover are valid")
  eq(t.icon, { kind = "emoji", value = CRAB })
  eq(t.cover, "assets/cover.png")
  local bad = task({ "title: T", "status: open", "icon: rocket", "cover: ../x.png" })
  ok(not bad.valid, "a bad icon makes the task invalid")
  ok(vim.tbl_contains(bad.error_codes, "bad-icon"), "bad-icon")
  ok(vim.tbl_contains(bad.error_codes, "bad-cover"), "bad-cover")
  eq(bad.icon, nil)
  eq(bad.cover, nil)
  local quoted = task({ "title: T", "status: open", 'icon: "' .. BOOK .. '"' })
  eq(quoted.icon, { kind = "emoji", value = BOOK }, "a quoted emoji")

  -- ── plans, projects and paths: the same reader ────────────────────────────
  for _, kind in ipairs({ "plan", "project", "path" }) do
    local f = plans.parse(
      "---\ntitle: P\nstatus: doing\nicon: assets/icon.svg\ncover: assets/c.jpg\n---\nBody.\n",
      { path = "/v/lib.nvim/ROADMAP/plans/p.md", area = "lib.nvim", kind = kind }
    )
    ok(f.valid, kind .. " is valid")
    eq(f.icon, { kind = "asset", value = "assets/icon.svg" }, kind)
    eq(f.cover, "assets/c.jpg", kind)
    local b = plans.parse(
      "---\ntitle: P\nstatus: doing\nicon: nope\ncover: x.png\n---\n",
      { path = "/v/lib.nvim/ROADMAP/plans/p.md", area = "lib.nvim", kind = kind }
    )
    ok(vim.tbl_contains(b.error_codes, "bad-icon"), kind .. ": bad-icon")
    ok(vim.tbl_contains(b.error_codes, "bad-cover"), kind .. ": bad-cover")
  end

  -- ── meetings: icon in three forms, cover, image as its old name ───────────
  local function meeting(lines)
    return meetings.parse(
      "---\ntitle: M\nstatus: planned\ndate: 2026-11-24\n" .. table.concat(lines, "\n") .. "\n---\n",
      { path = "/v/lib.nvim/MEETINGS/m.md", area = "lib.nvim", slug = "m" }
    )
  end
  local m = meeting({ "icon: " .. CRAB, "cover: assets/c.png" })
  ok(m.valid, "a meeting with an emoji")
  eq(m.icon, { kind = "emoji", value = CRAB })
  eq(m.cover, "assets/c.png")
  eq(m.image_alias, nil)
  local alias = meeting({ "image: assets/old.png" })
  eq(alias.cover, "assets/old.png", "image is read as cover")
  eq(alias.image_alias, true)
  local both = meeting({ "cover: assets/new.png", "image: assets/old.png" })
  eq(both.cover, "assets/new.png", "cover wins over image")
  ok(vim.tbl_contains(meeting({ "cover: assets/x.gif" }).error_codes, "meeting-bad-cover"))
  ok(vim.tbl_contains(meeting({ "image: assets/x.gif" }).error_codes, "meeting-bad-image"))
  ok(vim.tbl_contains(meeting({ "icon: rocket" }).error_codes, "meeting-bad-icon"))
  eq(meeting({ "icon: assets/i.svg" }).icon, { kind = "asset", value = "assets/i.svg" })
end
