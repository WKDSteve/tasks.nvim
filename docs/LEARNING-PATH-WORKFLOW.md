# Workflow: creating a learning path

Everything you need in one place to create a learning path (and, where it applies, a plan or project around it), with
checklists. The reference documents say *what* each command does ([COMMANDS.md](COMMANDS.md), [ENGINE.md](ENGINE.md));
the rules are `LP-01` to `LP-20` in `$RULES_VAULT/rulesets/arbeit/regeln/LERNPLAENE.md`; this document says *in which order
you do things, what to look up first and how you know you are done*. It is the same for the editor, the CLI, the desktop
app, the web variant and the mobile page: they all read the same file, `<area>/ROADMAP/paths/<slug>.md`.

Worked examples (read one before you start): `tricentis-vault/Learning/ROADMAP/paths/okta-tosca-cloud/`,
`neoload/`, `xtium-daas-poc/` (with exercise notes), `tasks-vault/ALL/ROADMAP/paths/cli-git-werkzeugkasten.md`.

## Contents

- [1. Decide what you are making](#1-decide-what-you-are-making)
- [2. Before you write: checklist](#2-before-you-write-checklist)
- [3. The steps](#3-the-steps)
- [4. Skeleton of a path file](#4-skeleton-of-a-path-file)
- [5. Writing good learning points](#5-writing-good-learning-points)
- [6. Sources and literature](#6-sources-and-literature)
- [7. XP, levels, badges (optional)](#7-xp-levels-badges-optional)
- [8. Check, commit, finish: checklist](#8-check-commit-finish-checklist)
- [9. Traps seen so far](#9-traps-seen-so-far)
- [10. Where you see the result](#10-where-you-see-the-result)

## 1. Decide what you are making

| You have | Make | Why |
| --- | --- | --- |
| One topic, one sitting, one result | a **task** with `## Lernpunkte` | no path needed (`LP-01`) |
| One topic with many sources, stages and a result | a **learning path** | progress over many points, no done date |
| Work that orders the learning (phases, effort) | a **plan** (`plan-new --template=learning`) | plans hold work, paths hold knowledge |
| Several paths towards one aim | a **project** (`project-new --template=learning`) | a curriculum |
| A competence you want to raise | a **competence** file, named in the path (`competence:`) | links learning to the matrix |

No path without a goal: a `target` or a competence goal in the first paragraph (`LP-01`).

## 2. Before you write: checklist

- [ ] **Machine** named (`NVIM_MACHINE_ROLE`; on a workstation nothing is built or installed for learning, `LP-09`).
- [ ] **Area and vault** chosen: tools and apps in `tasks-vault`, Tricentis work in `tricentis-vault` (`Learning`, `Horizon`, …); never invent an area.
- [ ] **Does it exist already?** `tasks paths --vault=…` and `tasks list <area> --tag=learning`; read neighbouring paths so you do not duplicate.
- [ ] **Primary material read** before any point is written: the local notes, the case/ticket (by number only, `LP-12`), the requirement document.
- [ ] **Goal sentence** written: "Be able to … without notes (T n, P n)".
- [ ] **Access list** made: licence, system, login; what is not available gets a substitute (`LP-09`).
- [ ] **Literature checked in the stock** first (`LP-11`, section 6) and gaps noted for the shopping list.
- [ ] **Sources opened**, or marked "unchecked" with the date (`LP-07`).
- [ ] **A task to claim** if one exists (`tasks claim <id> --by=<chat>`).

## 3. The steps

1. **Draft the file in a scratch folder** (not in the vault): frontmatter, goal, access, schedule, sources, tree, levels,
   self-check, open questions, repeat, "write the result back" (section 4).
2. **Dry run:** `tasks path-new <area> --from=<draft.md> --slug=<slug> --dry-run --vault=<vault>`. Every finding names the
   line and a code; warnings refuse as well. Fix until it says `would-create`.
3. **Create:** the same command without `--dry-run`.
4. **Images and badges:** `tasks attach <area>/<slug> <file> --by=<chat>` turns the path into a folder
   (`<slug>/<slug>.md`) and puts the file in `assets/`. Badges belong in `assets/badges/`: move them there. Relative links
   in the text need one more `../` after the folder form (traps, section 9).
5. **Link it:** `project:` in the frontmatter (or `path-new … --project=<id>`), `competence:` if there is a matrix row, `requires:` for paths it builds on.
6. **Create the follow-up task** the text promises, e.g. the repeat task (`LP-14`) and one task per result artefact; mention them by id, never as a list (`TASKS-03`).
7. **Check:** `tasks check <area> --vault=…` (own findings to zero), `tasks path <area>/<slug>` (XP per stage, no point without XP unless intended).
8. **Commit** with `tasks commit <paths…> --message=…` (own index, generated files included); pull and push per the repo rules.
9. **Report** in the running catalog (`tasks.nvim/ROADMAP/reports/`): what was awkward, what was missing, what ideas came up.

## 4. Skeleton of a path file

```markdown
---
title: "Topic: what you will be able to do"
status: planning            # planning | doing | parked
project: <area>/<project>   # optional
competence: <id>            # optional
links: [https://…]
icon: 🖥️                    # emoji, assets/icon.svg or a word of the list
created: 2026-11-23
updated: 2026-11-23
---

One sentence: the aim and its competence level (T 3, P 2).

## Ziel und Kompetenzstufe       <- goal, level, result artefacts, occasion, what is out of scope
## Zugang                        <- table: what / state / substitute
## Zeitplan                      <- table: session / duration / result (a session without a result does not count)
## Quellen                       <- table: source / type / what to watch / access / **checked** (date)
## Lernpunkte                    <- the tree, see section 5
## Level                         <- optional: thresholds, badges, rewards
## Selbstcheck                   <- 8 to 12 questions, answered in writing without notes (LP-13)
## Offene Fragen                 <- numbered, each with the point that waits for it
## Wiederholung                  <- after 1 week, 1 month, 3 months (LP-14), the repeat task by id
## Ergebnis schreiben            <- where the result flows back (LP-15)
## Notizen
```

Stage names are fixed (`LP-06`): `orientieren`, `grundlagen`, `vertiefen`, `anwenden`, `festigen`; leave out what you do not need.
Section titles stay German (the engine reads them); frontmatter keys and status values stay English.

## 5. Writing good learning points

Tree syntax (`LP-02`): `- [ ] text {#key}`, children indented by two spaces; marks `[ ]` open, `[x]` learned, `[~]` seen (with
reason), `[-]` not applicable (with reason), `[!]` blocked (with the key it waits for). Markers: `{xp=N}`, `{h=N}`,
`{optional}`, `{machine=private|workstation|wsl}`, `{safety}`, `{for=t4}`. No `→` in a label (it means "promoted task").
Keep every label on **one line**.

Checklist for **every point**:

- [ ] It is one action you can finish in one sitting (read, write, build, compare, answer).
- [ ] It carries a **key** if anything refers to it.
- [ ] It names the **source or the file** it works on, as a link.
- [ ] It has **XP** if the path counts XP (`xp-missing` hint shows the gaps).

Checklist for **every exercise or result point** (labels starting with "Üben", "Aufgabe", "Übung", "Ergebnis"):

- [ ] The point is a **title; the task is written out** under it as a quote (`> **Aufgabe:** …`): steps, sample values, the expected result.
- [ ] A **"Fertig, wenn"** line says how you can tell it is done (an artefact, a number, an output you can compare).
- [ ] The proof is named (note, table, protocol, screenshot as an asset) because "done" means proof, not "read" (`LP-04`).
- [ ] If the text is longer than about 10 lines or needs its own sub-points: **promote** it (`promote <path>#<key>`), the task then holds the steps as checkboxes (`LP-05`).
- [ ] Nothing in the point needs another AI prompt to become doable. A point like "Üben: `ls`, `ls -l`" without steps is a
  description, not a task; that mistake was found in 321 points of earlier paths (`tasks.nvim/uebungspunkte-mit-ausformulierter-aufgabe`).

Closing a stage: a point `Ergebnis: …` with the artefact. Closing the path: the self-check, then the write-back list.

## 6. Sources and literature

- Primary source first, with its **version** (`LP-08`); marketing statements are marked and checked against documentation or a trial.
- The sources table has a column **Geprüft**: a date, or "ungeprüft (how you saw it)", or "Login" for internal sources. Never leave it blank.
- **No customer data** in the path or its assets; cases appear by number only (`LP-12`).
- **Books from the stock** (`LP-11`): only chapters that answer a question of the plan.
  - Chapters of a book: `python $REPOS_DIR/Literatur/tools/litindex.py toc <path or name part>` (`--depth 2`, `--printed`).
  - Full-text search over all books: query the chapter index `Literatur/tools/.cache/fts.sqlite` (table `ch`, columns `book`, `chapter`, `path`, `page`) with an FTS5 `MATCH`; rebuild it with `litindex.py catalog`.
  - Link as a relative path from the path file to the PDF in `Literatur`, `Literatur-Security`, `Literatur-Web`, … (the stock is split over several repos; the catalog is `Literatur/Literaturliste.md`).
  - Put books in an `{optional}` group, so they do not count towards "path done".
  - If nothing fits, say so in the text and add the gap to the shopping list (`Literatur/Beschaffungsliste.md`); do not invent a chapter.

## 7. XP, levels, badges (optional)

XP are never computed from a scheme; each point states its own (`LP-18`). A path without levels is complete. If you add them:

- [ ] Thresholds in XP or percent, increasing; the last level is "Pfad fertig".
- [ ] A badge for each level as SVG in `assets/badges/`, referenced as `Badge assets/badges/<name>.svg`.
- [ ] A reward text after `Belohnung:`; suggestions only, the user changes them.
- [ ] Total XP is higher than the highest XP threshold (`tasks path` shows it).
- [ ] An AI proposes XP and rewards only on request, with reasons; accepting is by hand.

## 8. Check, commit, finish: checklist

- [ ] `tasks path-new … --dry-run` gave `would-create`; after creating, `tasks check <area>` shows no finding of your own.
- [ ] `tasks path <area>/<slug>`: points, XP per stage, "without xp" as intended, optional groups marked.
- [ ] Every relative link opens (check reports `path-link-missing`); external links are marked checked or unchecked.
- [ ] Images only as assets of the path folder, with a description (`LP-16`).
- [ ] No control characters from the editor (search the file once).
- [ ] Follow-up tasks exist (repeat, result artefacts) and are named by id.
- [ ] `status` is right (`doing` only if learning has started).
- [ ] Committed with `tasks commit`; pushed unless the repo forbids it (`tricentis-vault`: commit only).
- [ ] The catalog got your findings.

## 9. Traps seen so far

- `path-new --from` refuses a draft with `Badge assets/badges/…` (`level-badge-missing`): create the path **without** the badge text, attach the files, then add the text (`tasks.nvim/path-new-from-badges-neben-dem-entwurf`).
- `attach` puts files in `assets/`, not `assets/badges/`: move them.
- Folder form (after `attach`) breaks relative links by one level (`tasks.nvim/folderize-bricht-relative-links`): add one `../`.
- `attach` on your own claimed task needs `--by=<name>`.
- A `→` in a label makes it an "arrow to a promoted task" (`path-bad-arrow`).
- A label that spans two lines tears the point apart; `check` only says "without XP".
- Pipes in code break tables (`table-ragged`): write `\|`.
- `projects --of=<id>` needs `--write=<file>`; a project made without `--template=learning` has no `## Lernpfade` section.
- Never type long text through the shell (backslashes get lost): use the editor tool or a file (`FALLEN-01`).
- Do not trust a search hit: open the page before you mark a source as checked.

## 10. Where you see the result

| Surface | Where |
| --- | --- |
| Editor | `:Tasks path <area>/<slug>`, the dashboard; `tasks learn next` for the next points |
| CLI | `tasks path`, `tasks paths`, `tasks learn next|notes|evidence|history`, `tasks competences` |
| Desktop | tab **Learning plans** (paths with progress, map, next points, XP and levels; badges as images) |
| Web variant | the same views, `#view=paths`, `#view=pathmap` |
| Mobile page | through the hub of the PC; what the page shows of learning paths is not documented in `tasks-mobile/docs/USAGE.md` yet (open point of the feedback catalog) |

The apps only show the file; if something looks wrong there, fix the file, not the app.
