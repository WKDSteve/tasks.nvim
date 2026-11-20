// Checks the machine contract tasks-export/1 from the outside, the way a client would meet it.
//
//   npm ci && node check.mjs            checks everything, writes nothing, exit 1 on any failure
//   node check.mjs --write              also regenerates schemas/tasks-export/1/tasks-export.d.ts
//
// What it proves:
//  1. every golden document (TESTS/golden/tasks-export-1/*.json, made by the Lua engine) is valid against the JSON
//     Schema (draft 2020-12, Ajv in strict mode: a mistake in the schema itself fails too);
//  2. documents that break the contract are refused (a field nobody listed, a status outside the enum, ...), so the
//     schema is not just "accepts everything";
//  3. the rules for a reader hold: a higher schema is refused, unknown fields are ignored, an unknown enum word is
//     "unknown", a missing field is unknown and never 0;
//  4. the TypeScript types generated from the schema are the committed ones, and none of them is `never[]` (what the
//     generator makes of a tuple).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { compile } from "json-schema-to-typescript";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..");
const schemaPath = path.join(
  repo,
  "schemas/tasks-export/1/tasks-export.schema.json",
);
const typesPath = path.join(repo, "schemas/tasks-export/1/tasks-export.d.ts");
const goldenDir = path.join(repo, "TESTS/golden/tasks-export-1");
const write = process.argv.includes("--write");

let failures = 0;
const report = (ok, name, detail = "") => {
  if (!ok) failures += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ": " + detail : ""}`);
};

const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));

// ---- 1. the schema compiles (strict) and the goldens validate
const ajv = new Ajv2020({ strict: true, allErrors: true });
addFormats(ajv);
let validate;
try {
  validate = ajv.compile(schema);
  report(true, "schema compiles in strict mode (draft 2020-12)");
} catch (e) {
  report(false, "schema compiles in strict mode", e.message);
  process.exit(1);
}

const goldens = fs
  .readdirSync(goldenDir)
  .filter((f) => f.endsWith(".json"))
  .sort();
report(
  goldens.length >= 8,
  "golden documents found",
  `${goldens.length} files`,
);
const docs = {};
for (const file of goldens) {
  const doc = JSON.parse(fs.readFileSync(path.join(goldenDir, file), "utf8"));
  docs[file.replace(/\.json$/, "")] = doc;
  const ok = validate(doc);
  report(
    ok,
    `golden ${file} (${doc.kind})`,
    ok
      ? ""
      : JSON.stringify(
          validate.errors
            .slice(0, 3)
            .map((e) => `${e.instancePath} ${e.message}`),
        ),
  );
}

// ---- 2. documents that break the contract are refused
const mutate = (name, base, fn) => {
  const copy = structuredClone(docs[base]);
  fn(copy);
  report(!validate(copy), `refused: ${name}`);
};
mutate("an unknown top-level field", "snapshot", (d) => (d.surprise = 1));
mutate("an unknown task field", "snapshot", (d) => (d.tasks[0].surprise = 1));
mutate(
  "a status outside the enum",
  "snapshot",
  (d) => (d.tasks[0].status = "someday"),
);
mutate(
  "a readiness state nobody defined",
  "snapshot",
  (d) => (d.tasks[0].readiness.state = "maybe"),
);
mutate("a prio of 4", "snapshot", (d) => (d.tasks[0].prio = 4));
mutate("a sheet state nobody defined", "task-alpha", (d) => (d.task.sheets.state = "purple"));
mutate("sheet counts without a state", "task-alpha", (d) => delete d.task.sheets.counts.inbox);
mutate(
  "an effort that is no size or duration",
  "snapshot",
  (d) => (d.tasks[0].effort = "huge"),
);
mutate(
  "a task without its problems list",
  "snapshot",
  (d) => delete d.tasks[0].problems,
);
mutate("a vault id that is not a string", "snapshot", (d) => (d.vault.id = 7));
mutate("a views_rev that is no rev", "snapshot", (d) => (d.views_rev = "views:3"));
mutate("schema 2", "hello", (d) => (d.schema = 2));
mutate("a list with an option the engine does not have", "lists-builtin", (d) => (d.lists[0].options.colour = "red"));
mutate("a list from a source of its own", "lists-builtin", (d) => (d.lists[0].source = "cloud"));
// every option a stored list can carry (lists.FIELD_ORDER) is one the schema takes
{
  const copy = structuredClone(docs["lists-builtin"]);
  copy.lists[0].options.overdue = true;
  report(validate(copy), "accepted: a list with the switch overdue");
}
mutate("a grouping by a field the engine does not have", "groupings", (d) => (d.fields[0].field = "colour"));
mutate("a grouping that is written by an operation the engine does not have", "groupings", (d) => (d.fields[0].mode = "drag"));
mutate("a view drawn in a way the engine does not have", "views", (d) => (d.views[0].display = "cube"));
mutate("a view grouped by a field the engine does not have", "views", (d) => (d.views[0].group_by = "colour"));
mutate("a view without the version of its file", "views", (d) => delete d.views[0].etag);
mutate("an inverse of a view that is neither a save nor a delete", "result-views", (d) => (d.results[0].inverse.op = "view_rename"));
mutate("an inverse delete of a view without the version it deletes", "result-views", (d) => delete d.results[0].inverse.if_match);
mutate("an order by a word the engine does not have", "order-roi", (d) => (d.sort = "sideways"));
mutate(
  "a conflict group as a tuple",
  "snapshot",
  (d) => (d.plan.conflict_groups = [[0, ["a/b"]]]),
);
mutate(
  "a digest that is not a digest",
  "areas",
  (d) => (d.digest = "sha256:XYZ"),
);
mutate(
  "an etag with the wrong length",
  "task-alpha",
  (d) => (d.task.etag = "sha256:abc"),
);
mutate(
  "an error code outside the list",
  "error-unsupported-schema",
  (d) => (d.code = "oops"),
);
mutate("a list page without its total", "list-page", (d) => delete d.total);
mutate("a project link that is no web address", "snapshot", (d) => (d.projects[0].links = ["ftp://example.org/x"]));
mutate("a plan folder that is false", "snapshot", (d) => (d.projects[0].folder = false));
mutate("an icon of a kind nobody defined", "snapshot", (d) => (d.projects[0].icon.kind = "sticker"));
mutate("an icon without its value", "snapshot", (d) => delete d.projects[0].icon.value);
mutate("an icon as plain text", "meeting", (d) => (d.meeting.icon = "handshake"));
mutate("a cover outside assets/", "snapshot", (d) => (d.projects[0].cover = "../x.png"));
mutate("a phase suggestion that is no kebab-case word", "result-projects", (d) => {
  const failed = d.results.find((r) => r.error && r.error.details && r.error.details.suggestion);
  failed.error.details.suggestion = "Einführung";
});
mutate("a meeting with an unknown field", "meetings", (d) => (d.items[0].surprise = 1));
mutate("a meeting of a status nobody defined", "meetings", (d) => (d.items[0].status = "held"));
mutate("a meeting address of a service nobody defined", "meetings", (d) => (d.items[1].online_service = "skype"));
mutate("a meeting address that is no web address", "meetings", (d) => (d.items[1].online = "javascript:alert(1)"));
mutate("a meeting beginning that is no time", "meetings", (d) => (d.items[1].starts_at = "soon"));
mutate("a meeting task that is no id", "meetings", (d) => (d.items[1].tasks = ["alpha"]));
mutate("a notification with a field nobody defined", "meetings", (d) => (d.items[1].notify[0].when = "now"));
mutate("a meetings page without undated", "meetings", (d) => delete d.undated);
mutate("a quick proposal without a day", "meeting-parse", (d) => delete d.fields.date);
mutate("a quick proposal with a field meeting_new does not take", "meeting-parse", (d) => (d.fields.status = "done"));
mutate("a quick proposal with a time that is none", "meeting-parse", (d) => (d.fields.time = "25:00"));
mutate("a quick proposal with an address that is no web address", "meeting-parse", (d) => (d.fields.online = "msteams:x"));
mutate("a quick proposal of a service nobody defined", "meeting-parse", (d) => (d.online_service = "skype"));
mutate("a quick proposal that assumed something nobody defined", "meeting-parse-assumed", (d) => (d.assumed = ["time"]));
mutate("a meeting document of a kind of document nobody defined", "meeting", (d) => (d.documents[0].kind = "fax"));
mutate("a participant without a name", "meeting", (d) => delete d.participants[0].name);
mutate("a follow-up task that is no id", "meeting", (d) => (d.followups[0].task = "gamma"));
mutate("a task entry with more than 20 meetings", "task-with-meetings", (d) => {
  d.task.meetings = Array.from({ length: 21 }, (_, i) => `lib.nvim/m${i}`);
});
mutate("a check without its findings", "check", (d) => delete d.findings);
mutate("a finished list without its stats", "finished", (d) => delete d.stats);
mutate("a link of a kind nobody defined", "links", (d) => (d.pairs[0].edges[0].kind = "magic"));
mutate("a pair of areas without its count", "links", (d) => delete d.pairs[0].count);
mutate("a touched task with one area", "links", (d) => (d.tasks[0].areas = ["a"]));
mutate("a finished task with a made-up day", "finished", (d) => (d.items[0].done = "yesterday"));
mutate("a count row with a key nobody defined", "finished", (d) => (d.stats.by_area[0].colour = "red"));
mutate("a history without its points", "history", (d) => delete d.points);
mutate("a history point with a level but no states", "history", (d) => delete d.points[2].by_state);
mutate("a history point with a state nobody defined", "history", (d) => (d.points[2].by_state.frozen = 1));
mutate("a history point that counts below zero", "history", (d) => (d.points[2].open = -1));
mutate("a history by a resolution nobody defined", "history-weeks", (d) => (d.resolution = "month"));
mutate("a history point with a made-up day", "history-weeks", (d) => (d.points[0].day = "last week"));
mutate("rows of the series as text", "result-dry-run", (d) => (d.results.at(-1).rows = "one"));
mutate("a finding with a severity nobody defined", "check", (d) => (d.findings[0].severity = "fatal"));
mutate("a plan graph without its edges", "planfor", (d) => delete d.edges);
mutate("a plan graph whose edge kind nobody defined", "planfor", (d) => (d.edges[0].kind = "soft"));
mutate("an estimate without its range", "estimate", (d) => delete d.range);
mutate("an estimate that counts assumptions as text", "estimate", (d) => (d.assumed = "two"));
mutate("a plan comparison without its pace", "plancompare", (d) => delete d.plans[0].weekly_done);
mutate("a plan comparison with progress over one", "plancompare", (d) => (d.plans[0].progress = 1.5));
mutate("a plan comparison with a forecast of no weeks", "plancompare", (d) => (d.plans[0].forecast_weeks.low = 0));
mutate("a plan comparison with a prio of zero", "plancompare", (d) => (d.plans[0].prio = 0));
mutate("a plan comparison with a value that lacks its sum", "plancompare", (d) => delete d.plans[0].value.sum);
mutate("a plan comparison with a due day that is no date", "plancompare", (d) => (d.plans[0].target_due = "soon"));
mutate("a body without its etag", "bodies-page", (d) => delete d.items[0].etag);
mutate("a body page with a field nobody defined", "bodies-page", (d) => (d.items[0].path = "x"));
mutate("a waits_for that is no key", "list-waits-for", (d) => (d.items[0].waits_for = "My Mac"));
mutate("a waits_for of the filter word none", "list-waits-for", (d) => (d.items[0].waits_for = "none"));
mutate("a waits_for that is a list of keys", "list-waits-for", (d) => (d.items[0].waits_for = ["mac", "licence"]));
mutate("a waits overview without the number of parked tasks", "waits", (d) => delete d.parked);
mutate("a waits key that no task waits for", "waits", (d) => (d.keys[0].count = 0));
mutate("a waits key without its areas", "waits", (d) => delete d.keys[0].areas);
mutate("a waits overview with the tasks of a key", "waits", (d) => (d.keys[0].ids = ["lib.nvim/delta"]));
mutate(
  "an operation outcome nobody defined",
  "result-run",
  (d) => (d.results[0].outcome = "mostly"),
);
mutate(
  "an operation result without its position",
  "result-run",
  (d) => delete d.results[0].n,
);
mutate(
  "an operation that is not in the catalog",
  "result-run",
  (d) => (d.results[0].op = "delete"),
);
mutate(
  "a failure with an error code outside the list",
  "result-run",
  (d) => (d.results[1].error.code = "oops"),
);
mutate(
  "an inverse that is no operation",
  "result-run",
  (d) => (d.results[0].inverse.op = "rm"),
);
mutate(
  "a confirm token of the wrong shape",
  "donepreview",
  (d) => (d.confirm = "yes"),
);
mutate(
  "a dry-run flag that is not a boolean",
  "result-dry-run",
  (d) => (d.dry_run = "yes"),
);
mutate(
  "an empty object where an array belongs",
  "areas",
  (d) => (d.areas = {}),
);
mutate(
  "an array where an object belongs",
  "snapshot",
  (d) => (d.counts.by_status = []),
);
mutate("negative XP of a point", "path-xp", (d) => (d.nodes[1].xp = -5));
mutate("XP from a source nobody defined", "path-xp", (d) => (d.nodes[1].xp_from = "ai"));
mutate("XP of a tree without its maximum", "path-xp", (d) => delete d.xp.possible);
mutate("a level of a kind nobody defined", "path-xp", (d) => (d.levels[0].kind = "stars"));
mutate("a level ref that is neither a number nor done", "path-xp", (d) => (d.levels[0].ref = "first"));
mutate("a level state above 100 percent", "path-xp", (d) => (d.path.level.percent = 140));
mutate("a level problem without its code prefix", "path-xp", (d) => (d.level_problems[0].code = "order"));
mutate("an inverse reward without its level", "result-path-xp", (d) => (d.results[2].inverse.level = "zwei"));
mutate("an xp_clear that is false", "result-path-xp", (d) => (d.results[0].inverse.xp_clear = false));

// ---- 3. what a reader does with a document (the rules of the contract)
const SUPPORTED = 1;
const KNOWN_STATUS = new Set([
  "doing",
  "decision",
  "blocked",
  "open",
  "parked",
  "done",
]);

/** A minimal reader: refuses a newer schema, ignores unknown fields, never turns "missing" into 0. */
function readTask(entry) {
  return {
    id: String(entry.id),
    title: String(entry.title ?? ""),
    status: KNOWN_STATUS.has(entry.status) ? entry.status : "unknown",
    effortDays:
      typeof entry.effort_days === "number" ? entry.effort_days : undefined,
    roi: typeof entry.roi === "number" ? entry.roi : undefined,
    valid: entry.valid !== false,
  };
}
function readSnapshot(doc) {
  if (typeof doc.schema !== "number" || doc.schema > SUPPORTED) {
    throw new Error(
      `the engine speaks schema ${doc.schema}, this app speaks ${SUPPORTED}: update the app`,
    );
  }
  return { rev: doc.rev, tasks: doc.tasks.map(readTask) };
}

{
  const snap = structuredClone(docs.snapshot);
  const base = readSnapshot(snap);
  report(
    base.tasks.length === snap.tasks.length,
    "reader reads every task, broken ones included",
  );

  const withUnknown = structuredClone(snap);
  withUnknown.new_in_a_later_release = { a: 1 };
  withUnknown.tasks[0].new_field = "x";
  const read = readSnapshot(withUnknown);
  report(
    !("new_in_a_later_release" in read) && !("new_field" in read.tasks[0]),
    "reader ignores unknown fields",
  );

  const odd = structuredClone(snap);
  odd.tasks[0].status = "someday";
  report(
    readSnapshot(odd).tasks[0].status === "unknown",
    "reader shows an unknown enum word as unknown",
  );

  const gamma = read.tasks.find((t) => t.id === "lib.nvim/gamma");
  report(
    gamma.effortDays === undefined && gamma.roi === undefined,
    "missing means unknown, never 0 (no effort, no roi)",
  );

  const future = structuredClone(snap);
  future.schema = 2;
  let refused = false;
  try {
    readSnapshot(future);
  } catch (e) {
    refused = /update the app/.test(e.message);
  }
  report(refused, "reader refuses schema 2 and says what to do");

  const broken = read.tasks.find((t) => t.id === "lib.nvim/broken");
  report(
    broken && broken.valid === false,
    "a broken task is read, flagged valid=false",
  );
}

// ---- 5. the marker file tasks-vault.json (schemas/tasks-vault/1)
{
  const vaultDir = path.join(repo, "schemas/tasks-vault/1");
  const vaultSchema = JSON.parse(
    fs.readFileSync(path.join(vaultDir, "tasks-vault.schema.json"), "utf8"),
  );
  const vajv = new Ajv2020({ strict: true, allErrors: true });
  let vvalidate;
  try {
    vvalidate = vajv.compile(vaultSchema);
    report(true, "marker schema compiles in strict mode");
  } catch (e) {
    report(false, "marker schema compiles in strict mode", e.message);
    process.exit(1);
  }
  const example = JSON.parse(
    fs.readFileSync(path.join(vaultDir, "example.json"), "utf8"),
  );
  report(vvalidate(example), "marker example.json is valid");
  const minimal = {
    schema: 1,
    plugin: "tasks.nvim",
    kind: "tasks.vault",
    layout_version: 1,
  };
  report(vvalidate(minimal), "the four required keys alone are valid");
  const bad = {
    "an unknown key": { ...minimal, colour: "red" },
    "trust_vault_lint in the file": { ...minimal, ci: { trust_vault_lint: true } },
    "an unknown key in ci": { ...minimal, ci: { strict: true, x: 1 } },
    "a path as an area": { ...minimal, extra_areas: ["../x"] },
    "an absolute path as an area": { ...minimal, extra_areas: ["/etc"] },
    "a duplicate area": { ...minimal, extra_areas: ["ALL", "ALL"] },
    "a newer layout_version": { ...minimal, layout_version: 2 },
    "a newer schema": { ...minimal, schema: 2 },
    "a foreign plugin": { ...minimal, plugin: "obsidian-git" },
    "a foreign kind": { ...minimal, kind: "other" },
    "an unknown lang": { ...minimal, lang: "fr" },
    "a string for strict": { ...minimal, ci: { strict: "yes" } },
    "no layout_version": { schema: 1, plugin: "tasks.nvim", kind: "tasks.vault" },
  };
  for (const [name, doc] of Object.entries(bad)) {
    report(!vvalidate(doc), `marker schema refuses ${name}`);
  }
}

// ---- 4. the generated TypeScript
const types = await compile(schema, "TasksExport", {
  additionalProperties: false,
  bannerComment:
    "/* Generated from schemas/tasks-export/1/tasks-export.schema.json by contract/check.mjs. Do not edit. */",
});
report(
  !/never\[\]/.test(types),
  "generated types contain no never[] (the generator's answer to a tuple)",
);
report(
  /kind: "tasks\.snapshot"/.test(types) && /kind: "tasks\.error"/.test(types),
  "generated types carry the kinds",
);
if (write) {
  fs.writeFileSync(typesPath, types);
  console.log(`wrote ${path.relative(repo, typesPath)}`);
} else {
  const committed = fs.existsSync(typesPath)
    ? fs.readFileSync(typesPath, "utf8")
    : "";
  report(
    committed === types,
    "generated types equal the committed ones",
    committed === types
      ? ""
      : "run `node check.mjs --write` and commit schemas/tasks-export/1/tasks-export.d.ts",
  );
}

console.log(
  failures === 0
    ? "\nall contract checks passed"
    : `\n${failures} contract check(s) FAILED`,
);
process.exit(failures === 0 ? 0 : 1);
