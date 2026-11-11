/* Generated from schemas/tasks-export/1/tasks-export.schema.json by contract/check.mjs. Do not edit. */

/**
 * tasks-export/1: every document tasks.nvim hands to a machine. One of the kinds below, told apart by `kind`. The engine writes exactly these fields (a field that is not listed fails the contract tests); a reader ignores fields it does not know, because inside one version the contract only grows.
 */
export type TasksExport =
  | Hello
  | Snapshot
  | List
  | Order
  | NamedLists
  | Bodies
  | Estimate
  | PlanFor
  | PlanCompare
  | Check
  | TaskDocument
  | Next
  | Areas
  | Finished
  | Links
  | Groupings
  | Views
  | Waits
  | Find
  | Intent
  | DonePreview
  | Result
  | Error;
/**
 * tasks.hello: what this engine is and can do. Reads no task.
 */
export type Hello = Head & {
  kind: "tasks.hello";
  /**
   * The versions of the contract this engine speaks.
   */
  schemas: number[];
  /**
   * What it can answer; show only what is listed.
   */
  capabilities: string[];
  /**
   * The intents tasks takes (`wkd-intent/1`, appkit/schemas/wkd-intent/1): a sender offers only these actions and modes. Additive; capability `intent`.
   */
  intents?: {
    schema: "wkd-intent/1";
    actions: string[];
    modes: string[];
  };
  /**
   * The marker file of the vault (schemas/tasks-vault/1). Additive; capability `vault_marker`.
   */
  marker?: {
    /**
     * The vault has a marker file `tasks-vault.json` (valid or refused).
     */
    present: boolean;
    /**
     * Version of the folder layout the file names; absent when there is no valid file.
     */
    layout_version?: number;
    /**
     * Why the file is refused (every other call then fails with `invalid_argument` and this message); no path.
     */
    problem?: string;
  };
  limits: {
    title: number;
    summary: number;
    body_bytes: number;
    list_items: number;
    batch_ops: number;
  };
  /**
   * The ranges of the fields, from the engine, so that nobody hard-codes them.
   */
  enums: {
    status: string[];
    kind: string[];
    prio: number[];
    value: number[];
    effort: string[];
    actor: string[];
    category: string[];
    scope: string[];
    severity: string[];
    /**
     * The fixed acceptance lines a new task can start with, by kind, category and scope. A client joins the rows of what applies, each id once, in the order kind, category, scope (the order of the lists above); `implied` adds the rows of the named scopes when the kind and one of the categories match. The text follows the language of the task's headings (`de` or `en`).
     */
    scaffold?: {
      kind: ScaffoldRows;
      category: ScaffoldRows;
      scope: ScaffoldRows;
      implied: {
        kind: string;
        category: string[];
        scope: string[];
      }[];
    };
  };
};
/**
 * What the vault looked like: `rev:` and 6 hex digits, from every task by id and etag.
 */
export type Rev = string;
/**
 * The hash of the document's content (without `generated_at` and `engine`): the same vault gives the same digest.
 */
export type Digest = string;
/**
 * tasks.snapshot: one scan, one `rev`: counts, areas, the plan's head, the plan files and every open task with its readiness.
 */
export type Snapshot = Head & {
  kind: "tasks.snapshot";
  rev: Rev;
  /**
   * What the saved views looked like: the `rev` of `tasks.views` (`rev:` and 6 hex digits, from every file of a view by id and etag). A view changed outside changes it (and the digest), not `rev`: a reader that shows the views reads them again when it differs from the one it read.
   */
  views_rev?: string;
  digest: Digest;
  counts: {
    listed: number;
    unlisted: number;
    by_status: StatusCounts;
  };
  areas: Area[];
  /**
   * The area groups in force with their members; left out when the vault has none.
   */
  area_groups?: AreaGroup[];
  /**
   * Finished tasks that carry a reminder (`remind`), the oldest date first, at most 100. An open task's reminder is on its entry; a finished task is not in `tasks`, and a reminder is most often set when a task is finished.
   */
  reminders?: {
    id: string;
    area: string;
    title: string;
    remind: Date;
    etag?: Etag;
    done_in?: string;
  }[];
  /**
   * Task files in `ROADMAP/tasks` that are not open work: a finished task left there, a status nobody knows.
   */
  unlisted: {
    id: string;
    status: string;
    code: "done-in-roadmap" | "unknown-status" | "no-status";
  }[];
  plan: {
    summary: {
      tasks: number;
      ready: number;
      decision: number;
      waiting: number;
      stuck: number;
      freed: number;
      parked: number;
    };
    critical_path: {
      days: number;
      path: string[];
      /**
       * Tasks on the path without an effort (counted as one day each).
       */
      unknown_effort: number;
    };
    stage_sizes: number[];
    cycles: string[][];
    /**
     * Tasks of one stage that name the same file: not parallel work. A list of objects (a tuple would not survive the TypeScript generator).
     */
    conflict_groups: {
      stage: number;
      file: string;
      ids: string[];
    }[];
    warnings: {
      code: string;
      id?: string;
      msg: string;
    }[];
  };
  plans: {
    id: string;
    title: string;
    status?: "planning" | "doing" | "parked" | "done";
    areas: string[];
    target?: string;
    phase_order: string[];
    gate?: "hard";
    /**
     * The project the plan belongs to (capability `projects`).
     */
    project?: string;
    /**
     * The stage of that project the plan belongs to.
     */
    phase?: string;
    /**
     * The version of a file: `sha256:` and 16 hex digits of the hash of its bytes.
     */
    etag?: string;
    valid: boolean;
  }[];
  /**
   * The open project files (capability `projects`): a project groups plans and may hold tasks of its own.
   */
  projects: {
    id: string;
    title: string;
    status?: "planning" | "doing" | "parked" | "done";
    areas: string[];
    target?: string;
    phase_order: string[];
    gate?: "hard";
    /**
     * The version of a file: `sha256:` and 16 hex digits of the hash of its bytes.
     */
    etag?: string;
    valid: boolean;
    /**
     * The ids of the open plans of the project, sorted.
     */
    plans: string[];
    rollup: {
      plans_total: number;
      plans_done: number;
      plans_parked: number;
      tasks_open: number;
      tasks_done: number;
      own_open: number;
      days_open: number;
    };
  }[];
  /**
   * In plan order.
   */
  tasks: TaskEntry[];
  /**
   * Folders that could not be read: the answer may be incomplete.
   */
  incomplete: string[];
  estimate: {
    tasks: number;
    days: number;
    n_with_effort: number;
    n_without_effort: number;
    value: number;
    n_with_value: number;
    roi?: number;
    quick_wins: string[];
    unestimated: string[];
  };
};
/**
 * A calendar day, YYYY-MM-DD.
 */
export type Date = string;
/**
 * The version of a file: `sha256:` and 16 hex digits of the hash of its bytes.
 */
export type Etag = string;
/**
 * The statuses of a task in `ROADMAP/tasks`. `done` is only seen on a task that was left there after it was finished (listed under `unlisted`).
 */
export type Status = "doing" | "decision" | "blocked" | "open" | "parked" | "done";
export type Kind = "feature" | "task" | "bug" | "idea" | "research";
/**
 * A size (XS to XL) or a duration in days (`3d`, `0.5d`). `effort_days` is always the figure.
 */
export type Effort = string;
export type Actor = "cdx" | "me" | "pair";
export type Severity = "low" | "medium" | "high" | "critical";
export type Category =
  | "bug"
  | "security"
  | "performance"
  | "docs"
  | "ruleset"
  | "ux"
  | "bindings"
  | "refactor"
  | "tests"
  | "ci"
  | "learning";
export type Scope =
  "usercmd" | "keymap" | "config" | "ui" | "api" | "docs" | "tests" | "health" | "migration" | "multi-repo";
/**
 * tasks.list: one page of tasks in plan order, or in the order the request named (`sort`).
 */
export type List = Head & {
  kind: "tasks.list";
  rev: Rev;
  digest: Digest;
  total: number;
  offset: number;
  limit: number;
  items: TaskEntry[];
  /**
   * Absent on the last page.
   */
  next_offset?: number;
  incomplete: string[];
};
/**
 * tasks.order: the ids of the open tasks in the order the request named (`sort`; "default" is the plan's order), all in one document.
 */
export type Order = Head & {
  kind: "tasks.order";
  digest: Digest;
  sort:
    | "default"
    | "prio-effort"
    | "severity"
    | "frecency"
    | "roi"
    | "due"
    | "created-desc"
    | "created-asc"
    | "updated-desc"
    | "updated-asc"
    | "remind"
    | "title";
  total: number;
  ids: string[];
  incomplete: string[];
};
/**
 * tasks.lists: the named lists of the engine, read only: the built-in ones, the ones saved with the editor and the ones of the configuration (the later source wins by name), by name. `notes` tell what had to be left out (a rejected definition, a shadowed list, a state file that cannot be read), in the engine's words and without a path of this machine.
 */
export type NamedLists = Head & {
  kind: "tasks.lists";
  digest: Digest;
  lists: NamedList[];
  notes: string[];
};
/**
 * tasks.bodies: the text of many tasks, a page at a time, for a reader that searches it. Its `rev` is that of the snapshot of the same vault.
 */
export type Bodies = Head & {
  kind: "tasks.bodies";
  rev: Rev;
  digest: Digest;
  total: number;
  offset: number;
  limit: number;
  items: {
    id: string;
    etag: Etag;
    /**
     * The file after the frontmatter, untrusted text.
     */
    body: string;
    body_truncated: boolean;
  }[];
  /**
   * Absent on the last page; where to go on when a page ended early (it holds as many bytes as a page may).
   */
  next_offset?: number;
  incomplete: string[];
};
/**
 * tasks.estimate: the figures of an estimate for some open tasks, also as they would be with other efforts and values (`assume`; nothing is written). The same figures as `estimate` in the snapshot, with the range of the sizes.
 */
export type Estimate = Head & {
  kind: "tasks.estimate";
  rev: Rev;
  digest: Digest;
  tasks: number;
  days: number;
  /**
   * The sum with every size at its low and at its high end: without it the sum looks more exact than it is.
   */
  range: {
    low: number;
    high: number;
  };
  n_with_effort: number;
  n_without_effort: number;
  value: number;
  n_with_value: number;
  n_without_value: number;
  roi?: number;
  quick_wins: string[];
  unestimated: string[];
  /**
   * How many of the tasks were taken with assumed values.
   */
  assumed: number;
  incomplete: string[];
};
/**
 * tasks.planfor: the tasks one task needs before it can start (`needs`) or the tasks that wait for it (`unlocks`), with the hard edges between them, in the order of their distance from the task. The same tasks as `plan --for`.
 */
export type PlanFor = Head & {
  kind: "tasks.planfor";
  rev: Rev;
  digest: Digest;
  id: string;
  direction: "needs" | "unlocks";
  /**
   * All the tasks in the graph; `nodes` holds at most 500 of them.
   */
  total: number;
  truncated: boolean;
  nodes: {
    id: string;
    title: string;
    status: string;
    state?: string;
    stage?: number;
    /**
     * Steps from the task itself (0).
     */
    distance: number;
    on_critical_path?: true;
  }[];
  edges: {
    /**
     * The task that has to be finished first.
     */
    from: string;
    /**
     * The task that waits.
     */
    to: string;
    kind: "blocked_by" | "gate";
  }[];
  /**
   * The cycles whose members are all among `nodes`.
   */
  cycles: string[][];
  incomplete: string[];
};
/**
 * tasks.plan_compare (capability `plan_compare`): the open plans side by side, one row each in the order of the vault (`ids` narrows it to some). The figures are the engine's; a page that compares plans only sorts and draws them. The finished tasks lie outside the revision, as in `tasks.finished`.
 */
export type PlanCompare = Head & {
  kind: "tasks.plan_compare";
  rev: Rev;
  digest: Digest;
  today: Date;
  weeks: number;
  plans: PlanCompareRow[];
  incomplete: string[];
};
/**
 * tasks.check: the rule check of the vault (`tasks check`), with `stale: refs` also the open tasks that name a file which changed after the task was updated. It reads every task file: a client runs it as a job.
 */
export type Check = Head & {
  kind: "tasks.check";
  rev: Rev;
  digest: Digest;
  /**
   * No finding of severity error.
   */
  ok: boolean;
  errors: number;
  warnings: number;
  /**
   * Areas checked.
   */
  areas: number;
  /**
   * Task files read, open and finished.
   */
  tasks: number;
  stale?: "refs";
  /**
   * All the findings; `findings` holds at most 1000 of them.
   */
  total: number;
  truncated: boolean;
  findings: {
    /**
     * A stable rule code, e.g. `unknown-status`.
     */
    code: string;
    severity: "error" | "warn";
    area: string;
    /**
     * The task the finding is about, when there is one.
     */
    id?: string;
    /**
     * Relative to the vault.
     */
    file: string;
    /**
     * The engine's words; untrusted text.
     */
    message: string;
  }[];
  /**
   * What could not be checked (git missing, a budget used up).
   */
  notes: string[];
  incomplete: string[];
};
/**
 * tasks.task: one task with its body and steps.
 */
export type TaskDocument = Head & {
  kind: "tasks.task";
  rev: Rev;
  digest: Digest;
  task: TaskEntry;
  /**
   * The file after the frontmatter, untrusted text.
   */
  body: string;
  body_truncated: boolean;
  steps: {
    n: number;
    text: string;
    ticked: boolean;
    dropped: boolean;
  }[];
  /**
   * The questions of the `## Offene Fragen` / `## Open questions` section, in the order written; empty without the section. A question is answered when exactly one option is ticked; `answer` writes it.
   */
  questions?: {
    n: number;
    /**
     * `q1`; absent for a question written without one (the first `answer` gives it one). `answer` takes the key.
     */
    key?: string;
    title: string;
    text: string;
    answered: boolean;
    options: {
      n: number;
      text: string;
      recommended: boolean;
      chosen: boolean;
    }[];
  }[];
  /**
   * Only for a routine (`task.repeat`; capability `rounds`): its finished rounds, newest first, at most 100. A round is a task file below `<area>/Backlog/` that carries `repeat` and shares the routine's slug without the due date a round adds. `done` is the date in its file name (absent without one). The rounds lie outside the revision, as in `tasks.finished`.
   */
  rounds?: {
    id: string;
    done?: Date;
    due?: Date;
    status?: Status;
    done_in?: string;
    commits?: string[];
  }[];
  /**
   * Present (true) when the routine has more finished rounds than `rounds` holds.
   */
  rounds_truncated?: true;
};
/**
 * tasks.next: what to start, with the reason; or why there is nothing.
 */
export type Next = Head & {
  kind: "tasks.next";
  digest: Digest;
  task?: TaskBrief;
  alternatives: TaskBrief[];
  /**
   * Ready tasks an AI session could take, apart from yours.
   */
  cdx: TaskBrief[];
  freed: string[];
  ready: {
    area: number;
    vault: number;
  };
  open: {
    area: number;
    vault: number;
  };
  /**
   * Ready tasks left out because their `start` day has not come yet; absent when none.
   */
  later?: number;
  /**
   * Ready tasks left out because somebody else has claimed them (capability `claims`); absent when none.
   */
  claimed?: number;
  /**
   * Present when there is no task to start: which kind of nothing it is. `all_done` is only said when nothing is open at all.
   */
  empty?: {
    kind: "all_done" | "nothing_startable" | "only_cdx";
    waiting: number;
    for_me: number;
    blocked_status: number;
    parked: number;
    /**
     * Of the parked tasks: how many wait for each `waits_for` key. Left out when none of them names one.
     */
    waits_for?: {
      [k: string]: number;
    };
    unlisted: number;
    unreadable: number;
  };
  incomplete: string[];
};
/**
 * tasks.areas: the areas of the vault with their open counts.
 */
export type Areas = Head & {
  kind: "tasks.areas";
  /**
   * The area groups in force with their members; left out when the vault has none.
   */
  area_groups?: AreaGroup[];
  digest: Digest;
  areas: Area[];
};
/**
 * tasks.finished: the finished tasks of the Backlogs, newest first, one page, and what ALL that match add up to. Asked with `since` and `until` (days, both included) it covers the tasks `done` ran for in that window; the area is the one the file is in now.
 */
export type Finished = Head & {
  kind: "tasks.finished";
  digest: Digest;
  total: number;
  offset: number;
  limit: number;
  items: FinishedItem[];
  /**
   * Absent on the last page.
   */
  next_offset?: number;
  /**
   * Finished files (of the area asked for) without a `YYYY-MM-DD_` in the name: they are in the figures only when no window is asked for.
   */
  undated: number;
  stats: FinishedStats;
  incomplete: string[];
};
/**
 * tasks.links: where the areas hang together. A link is a `blocked_by` or `after` to an open task of another area, a ref that names another area (`lib.nvim@803de65`, `lib.nvim:anchor`; a path says nothing about the repo), or a plan whose open tasks lie in several areas. `pairs` groups the edges by the two areas (`a` sorts before `b`, the busiest pair first); `tasks` lists, for every open task that touches two or more areas, the areas it touches (its own and those of every link it is part of, in both directions). The edges of the pairs are cut at 2000 (`truncated`); `edge_count`, the counts and `tasks` cover all of them.
 */
export type Links = Head & {
  kind: "tasks.links";
  rev: Rev;
  digest: Digest;
  edge_count: number;
  truncated: boolean;
  pairs: {
    a: string;
    b: string;
    count: number;
    kinds: {
      [k: string]: number;
    };
    edges: LinkEdge[];
  }[];
  tasks: {
    id: string;
    /**
     * @minItems 2
     */
    areas: [string, string, ...string[]];
  }[];
  incomplete: string[];
};
/**
 * tasks.groupings: the fields the open tasks can be grouped by, with the values each can have and how a reader writes it. `status`, `prio`, `actor`, `kind`, `effort` and `value` are the model's; `tags`, `plan`, `phase` and `project` (derived: the project of the task's plan, or its own) are the ones the open tasks name (at most 200, `truncated` says the rest); `area` is the areas of the vault; `state` and `cross` are derived (`cross`: `several` for a task `tasks.links` names among the tasks that touch two or more areas, else `one`). `mode` says which operation writes the field: `set` (a field of the file), `tags` (the list of tags: leaving one and taking another is one `set` of the whole list) or `move_area`; a field without `mode` is read only. The same `rev` as the snapshot of the same vault.
 */
export type Groupings = Head & {
  kind: "tasks.groupings";
  rev: Rev;
  digest: Digest;
  fields: {
    field:
      | "status"
      | "prio"
      | "actor"
      | "kind"
      | "effort"
      | "value"
      | "tags"
      | "plan"
      | "phase"
      | "project"
      | "area"
      | "state"
      | "cross";
    values: string[];
    truncated: boolean;
    writable: boolean;
    value_type: "string" | "number";
    mode?: "set" | "tags" | "move_area";
    multi?: boolean;
  }[];
};
/**
 * tasks.views: the saved views of the vault (`<area>/ROADMAP/views/<slug>.md`), sorted by id. A file that cannot be read as a view is no view but a line of `problems`. The `rev` is that of the views, not of the tasks.
 */
export type Views = Head & {
  kind: "tasks.views";
  rev: Rev;
  digest: Digest;
  views: View[];
  problems: {
    id: string;
    file: string;
    message: string;
  }[];
};
export type GroupField =
  | "status"
  | "prio"
  | "actor"
  | "kind"
  | "effort"
  | "value"
  | "tags"
  | "plan"
  | "phase"
  | "project"
  | "area"
  | "state"
  | "cross";
/**
 * tasks.waits: what the parked tasks wait for, of the vault or of one area (or area group). `keys` are the `waits_for` keys in use, the one with the most tasks first (then by name), each with its number of parked tasks and their areas. `parked` counts every parked task: the ones of `keys`, `without_reason` (parked by choice, no `waits_for`) and `invalid` (a `waits_for` that is no key, the `invalid-waits-for` finding). Same `rev` as the snapshot of the same state.
 */
export type Waits = Head & {
  kind: "tasks.waits";
  rev: Rev;
  digest: Digest;
  parked: number;
  without_reason: number;
  invalid: number;
  keys: {
    key: WaitsKey;
    count: number;
    areas: string[];
  }[];
  /**
   * Folders that could not be read: the answer may be incomplete.
   */
  incomplete: string[];
};
/**
 * What a parked task waits for from outside (`waits_for`): one word of the vault's own, lower-case letters, digits and `-`. `none` is no key (it is what a filter calls a parked task without one).
 */
export type WaitsKey = string;
/**
 * tasks.find: the tasks, open and finished, whose `refs` name one of the refs asked for (capability `find`). Open tasks first, then by id.
 */
export type Find = Head & {
  kind: "tasks.find";
  matches: FindMatch[];
};
/**
 * tasks.intent: what tasks did with an intent `wkd-intent/1` (capability `intent`): `would_create` (a dry run), `created` (with `yes`), `exists` (a task holds the ref `testing-finding:<fp>` already: `matches`), `shown` or `not_found` (`tasks.show`). A refused intent is an error (`invalid_argument`, every problem in the message), nothing written.
 */
export type Intent = Head & {
  kind: "tasks.intent";
  action: "tasks.new" | "tasks.show";
  outcome: "would_create" | "created" | "exists" | "shown" | "not_found";
  id?: string;
  area?: string;
  title?: string;
  status?: string;
  location?: "open" | "done";
  matches?: FindMatch[];
};
/**
 * tasks.donepreview: what finishing a task would do, with nothing written, and the `confirm` token that `done` needs for exactly this version of the file.
 */
export type DonePreview = Head & {
  kind: "tasks.donepreview";
  digest: Digest;
  id: string;
  /**
   * The task is finished already: nothing to confirm.
   */
  already?: true;
  area?: string;
  bucket?: "FEATURES" | "TASKS";
  from?: string;
  to: string;
  resumed?: boolean;
  steps_ticked?: number;
  readme?: {
    state: "missing" | "updated" | "unchanged";
    row?: string;
  };
  plan?: string;
  /**
   * The plan this finish closes: the task is its last open member.
   */
  closes_plan?: string;
  /**
   * The project this finish closes after that: no other plan (a parked one does not count) and no task of its own is open (capability `projects`).
   */
  closes_project?: string;
  /**
   * Present when the task is a routine (`repeat`): the due date of the round the finish starts.
   */
  next_round?: {
    due: Date;
  };
  /**
   * Open tasks that wait on nothing but this one.
   */
  freed?: string[];
  etag?: Etag;
  confirm?: string;
};
/**
 * tasks.result: the answer to a request of `tasks-ops/1`, one entry per operation. `ok` is true only when every operation was.
 */
export type Result = Head & {
  kind: "tasks.result";
  digest: Digest;
  client_op_id?: string;
  dry_run: boolean;
  ok: boolean;
  results: ResultEntry[];
};
/**
 * Why something failed, in a word that is stable. A reader treats a word it does not know as `internal`.
 */
export type ErrorCode =
  | "invalid_argument"
  | "not_found"
  | "conflict"
  | "exists"
  | "forbidden"
  | "locked"
  | "lock_stuck"
  | "unsupported_schema"
  | "payload_too_large"
  | "rollback_incomplete"
  | "io"
  | "internal";
/**
 * tasks.error: what went wrong, in a code that is stable. `message` carries no path of the machine.
 */
export type Error = Head & {
  kind: "tasks.error";
  code: ErrorCode;
  message: string;
  retryable: boolean;
  details?: {};
};

/**
 * What every document starts with.
 */
export interface Head {
  schema: 1;
  plugin: "tasks.nvim";
  kind: string;
  generated_at: string;
  vault: {
    id: string;
  };
  engine: {
    version: string;
    git: string;
    nvim: string;
  };
  rev?: Rev;
  digest?: Digest;
}
/**
 * Acceptance lines by word of a list (a kind, a category or a scope).
 */
export interface ScaffoldRows {
  [k: string]: {
    id: string;
    de: string;
    en: string;
  }[];
}
export interface StatusCounts {
  [k: string]: number;
}
export interface Area {
  name: string;
  open: number;
  by_status: StatusCounts;
}
/**
 * An area group (`<vault>/area-groups.json`, in Neovim also `setup({ area_groups })`): a filter name that stands for several areas. The methods `list`, `order`, `next` and `finished` take a group name for `area` too (`check` takes one area); a write target never is one. Only groups in force are listed (an area of the same name wins).
 */
export interface AreaGroup {
  name: string;
  /**
   * The areas of the vault the group stands for, sorted.
   */
  members: string[];
  open: number;
  by_status: StatusCounts;
  desc?: string;
}
/**
 * One task. A broken task is still here (`valid: false`, `problems`); a field that is missing is unknown, never 0 (no `effort` means no `effort_days` and no `roi`).
 */
export interface TaskEntry {
  id: string;
  area: string;
  slug: string;
  title: string;
  status?: Status;
  kind?: Kind;
  prio?: number;
  /**
   * A tie-breaker inside a stage; a fraction slots a task in between.
   */
  order?: number;
  effort?: Effort;
  effort_days?: number;
  value?: number;
  /**
   * Value per effort day (never less than a quarter of a day), rounded to two places.
   */
  roi?: number;
  actor?: Actor;
  /**
   * True when `actor` is what the file says, absent when it was derived.
   */
  actor_written?: boolean;
  severity?: Severity;
  /**
   * What the task waits for from outside, as its file says; meant for a `parked` task (the engine drops it when the status leaves `parked`). Absent for a task that names none, and for a value that is no key (the `invalid-waits-for` problem).
   */
  waits_for?: string;
  created?: Date;
  updated?: Date;
  /**
   * A calendar day, YYYY-MM-DD.
   */
  remind?: string;
  /**
   * A calendar day, YYYY-MM-DD.
   */
  due?: string;
  /**
   * A calendar day, YYYY-MM-DD.
   */
  start?: string;
  /**
   * Somebody works on the task (optional; capability `claims`): who, since when, until when (UTC). `expired` is the engine's judgement when the document was made; a reader that keeps it compares `until` with its own clock. An expired claim counts as free.
   */
  claim?: {
    by: string;
    since: string;
    until: string;
    expired: boolean;
  };
  /**
   * A routine (optional): every N days, weeks, months or years (`8w`). Finishing the task starts the next round. Capability `repeat`.
   */
  repeat?: string;
  /**
   * Where the next round counts from: the day the round was finished (`done`, the default) or the due date of the finished round (`due`, a fixed rhythm).
   */
  repeat_from?: "done" | "due";
  plan?: string;
  /**
   * The project the task belongs to directly, instead of a plan (capability `projects`).
   */
  project?: string;
  phase?: string;
  done_in?: string;
  commits?: string[];
  tags: string[];
  category: Category[];
  /**
   * What the task touches (optional, only when the task names a scope).
   */
  scope?: Scope[];
  blocked_by: string[];
  after: string[];
  /**
   * As written, but a path of the machine shows as `<external>/<name>`.
   */
  refs: string[];
  /**
   * Web addresses of the task (`http://` or `https://`), apart from `refs`. Only when the task lists any.
   */
  links?: string[];
  summary: string;
  folder: boolean;
  /**
   * Relative to the vault, with `/`.
   */
  file: string;
  valid: boolean;
  problems: Problem[];
  steps?: Steps;
  sheets?: Sheets;
  /**
   * How many questions of the `## Offene Fragen` section of the task are not answered; absent when none is open.
   */
  open_questions?: number;
  etag?: Etag;
  readiness?: Readiness;
  /**
   * `status|eff_prio`: inside one group `order` decides.
   */
  group?: string;
}
export interface Problem {
  code: string;
  msg: string;
}
/**
 * The steps of the optional `## Plan` section; a dropped one is not counted.
 */
export interface Steps {
  total: number;
  ticked: number;
  dropped: number;
}
/**
 * The test-sheet block testing.nvim writes into the task (`testing sheets report --tasks`), from its states line; absent without the block. `state` is the worst sheet (red, stale, never, inbox = green and waiting for a person's judgement, manual, green), `unknown` for a block without a states line. Nothing is run: it is what the last report wrote.
 */
export interface Sheets {
  state: "red" | "stale" | "never" | "inbox" | "manual" | "green" | "unknown";
  total: number;
  counts: {
    red: number;
    stale: number;
    never: number;
    inbox: number;
    manual: number;
    green: number;
  };
  /**
   * Why the state is `unknown`: the block has no states line (an older testing.nvim), no state this engine knows is in it (a newer testing.nvim), or its markers are broken (two blocks, a begin without its end; testing.nvim does not write such a body). Absent otherwise.
   */
  reason?: "no-states-line" | "no-known-state" | "broken-markers";
}
/**
 * Where a task stands in the plan, from `blocked_by` alone.
 */
export interface Readiness {
  state: "ready" | "decision" | "waiting" | "stuck" | "freed" | "parked" | "unknown";
  /**
   * Absent for a task in a cycle.
   */
  stage?: number;
  /**
   * Position in plan order, 1 is first.
   */
  rank: number;
  eff_prio?: number;
  leverage: number;
  open_blockers: string[];
  inversion?: {
    from?: number;
    to: number;
    because: string;
  };
  in_cycle?: true;
  same_file?: string[];
}
/**
 * A named list: a filter and an order under a name. `options` are the option words of the command line (`tasks list --effort=<=S --sort=roi`), a switch is present as `true` and absent when off; a list the engine rejects is not here but in `notes` of the document. `summary` is the one line the engine shows for it (its description, else the words).
 */
export interface NamedList {
  name: string;
  source: "builtin" | "saved" | "config";
  desc?: string;
  summary: string;
  options: {
    area?: string;
    sort?: string;
    status?: string;
    prio?: string;
    effort?: string;
    kind?: string;
    category?: string;
    severity?: string;
    waits_for?: string;
    value?: string;
    actor?: string;
    tag?: string;
    sheet?: string;
    stale?: string;
    plan?: string;
    phase?: string;
    blocked?: true;
    reminders?: true;
    overdue?: true;
    unestimated?: true;
    stale_refs?: true;
    quick_win?: true;
    readiness?: "ready" | "waiting";
  };
}
/**
 * One open plan of tasks.plan_compare. `tasks`: its open and finished tasks, the open ones by readiness state. `effort`: open days (with the range of the sizes), finished days, open tasks without an effort. `path`: the critical path of the plan's open tasks alone (a blocker outside the plan takes no part). `weekly_done`: members finished in each of the last `weeks` weeks, oldest first (the last week ends `today`). `forecast_weeks`: weeks the open tasks would still take, `low` at the pace of the best of those weeks, `high` at their average; absent when nothing was finished in them or nothing is open. `phase_now`: the first stage of the plan's `phase_order` that still has an open task.
 */
export interface PlanCompareRow {
  id: string;
  title: string;
  status?: string;
  project?: string;
  stages: number;
  phase_now?: string;
  tasks: {
    open: number;
    done: number;
    ready: number;
    decision: number;
    waiting: number;
    stuck: number;
    freed: number;
    parked: number;
  };
  progress: number;
  effort: {
    open_days: number;
    open_low: number;
    open_high: number;
    done_days: number;
    open_without: number;
  };
  path: {
    days: number;
    unknown_effort: number;
  };
  last_done?: Date;
  weekly_done: number[];
  forecast_weeks?: {
    low: number;
    high: number;
  };
}
export interface TaskBrief {
  id: string;
  title: string;
  status?: Status;
  prio?: number;
  effort?: string;
  reason?: "freed" | "area" | "vault";
}
/**
 * A finished task of `Backlog/`: what the engine knows without the plan (a finished task has no readiness). `done` is the day in the file's name; absent for a file without one.
 */
export interface FinishedItem {
  id: string;
  area: string;
  slug: string;
  title: string;
  done?: Date;
  kind?: Kind;
  prio?: number;
  effort?: Effort;
  effort_days?: number;
  value?: number;
  tags: string[];
  plan?: string;
  phase?: string;
  done_in?: string;
  commits?: string[];
  file: string;
}
/**
 * What the finished tasks add up to, over ALL that match the window (not the page). A task that does not carry the field has a row without the key (missing means unknown). The rows of `by_month` and `by_week` are oldest first, the others the biggest first.
 */
export interface FinishedStats {
  /**
   * The sum of the efforts that are written down.
   */
  effort_days: number;
  /**
   * Tasks without an effort (not counted in `effort_days`).
   */
  without_effort: number;
  by_area: {
    area: string;
    count: number;
    effort_days: number;
  }[];
  by_kind: {
    kind?: Kind;
    count: number;
    effort_days: number;
  }[];
  by_prio: {
    prio?: number;
    count: number;
    effort_days: number;
  }[];
  by_month: {
    month?: string;
    count: number;
    effort_days: number;
  }[];
  by_week: {
    /**
     * A calendar day, YYYY-MM-DD.
     */
    week?: string;
    count: number;
    effort_days: number;
  }[];
}
/**
 * One link between the open tasks of two areas, seen from the task it starts at. `to` is the other task (`blocked_by`, `after`) or the plan (`plan`); `ref` is the ref as written (`refs`).
 */
export interface LinkEdge {
  from: string;
  from_area: string;
  to_area: string;
  kind: "blocked_by" | "after" | "refs" | "plan";
  to?: string;
  ref?: string;
}
/**
 * One saved view: a selection (which tasks), a grouping (by which field, a matrix by a second one) and how it is drawn. It holds no task and no rule. `etag` is the version of its file: a change is made on it (`view_save`, `view_delete`).
 */
export interface View {
  /**
   * `<area>/<slug>`.
   */
  id: string;
  area: string;
  title: string;
  display: "columns" | "list" | "matrix";
  group_by: GroupField;
  /**
   * The field of the rows of a matrix (never the field of the columns).
   */
  group_by2?:
    | "status"
    | "prio"
    | "actor"
    | "kind"
    | "effort"
    | "value"
    | "tags"
    | "plan"
    | "phase"
    | "project"
    | "area"
    | "state"
    | "cross";
  /**
   * The groups that are folded (the values as `tasks.groupings` names them).
   */
  collapsed: string[];
  select: ViewSelect;
  etag: Etag;
  created?: string;
  updated?: string;
}
/**
 * Which tasks a view shows: every list narrows (an empty list does not), `query` is a word the title must hold.
 */
export interface ViewSelect {
  areas: string[];
  statuses: string[];
  actors: string[];
  kinds: string[];
  tags: string[];
  plans: string[];
  projects?: string[];
  query?: string;
}
/**
 * A task that names a ref: the ref, the task (id, area, status) and where it is, `open` (ROADMAP) or `done` (Backlog). Never a path.
 */
export interface FindMatch {
  ref: string;
  id: string;
  area: string;
  status: string;
  location: "open" | "done";
}
/**
 * What happened to one operation of a request, in the order they were sent. A failed operation does not stop the others.
 */
export interface ResultEntry {
  n: number;
  op:
    | "set"
    | "new"
    | "reorder"
    | "done"
    | "move_area"
    | "plan_new"
    | "plan_set"
    | "plan_close"
    | "project_new"
    | "project_set"
    | "project_close"
    | "tick_step"
    | "add_steps"
    | "answer"
    | "append_note"
    | "reopen"
    | "set_body"
    | "view_save"
    | "view_delete"
    | "attach"
    | "claim"
    | "release";
  id?: string;
  ok: boolean;
  /**
   * `would_*` is what a dry run says; `blocked` is a move that cannot be made.
   */
  outcome:
    | "changed"
    | "unchanged"
    | "created"
    | "done"
    | "would_change"
    | "would_create"
    | "would_done"
    | "would_move"
    | "moved"
    | "deleted"
    | "would_delete"
    | "closed"
    | "would_close"
    | "blocked"
    | "failed";
  etag_before?: Etag;
  etag_after?: Etag;
  inverse?: Inverse;
  /**
   * What a reorder wrote: these `set` operations give every file it wrote its old `order` back (send them all instead of `inverse`, which only restores the place: a task that had no `order` would keep one, and the neighbours the move numbered stay numbered).
   */
  restore?: Inverse[];
  /**
   * Ids whose files this operation wrote (a dry run: none).
   */
  changed_ids: string[];
  /**
   * What happened to the generated index of the area, once for the whole request.
   */
  index?: {
    action: "written" | "removed" | "unchanged" | "stale" | "error";
    error?: string;
  };
  error?: OperationError;
  file?: string;
  group?: string;
  renumbered?: boolean;
  /**
   * `plan_new`: the file name (without `.md`) the plan got or would get.
   */
  slug?: string;
  /**
   * `plan_new`: the slug asked for was taken, so another one was chosen.
   */
  renamed?: boolean;
  /**
   * `attach`: the path of the new asset below the task folder, e.g. `assets/shot.png`.
   */
  asset?: string;
  /**
   * `attach`: the Markdown that links the asset (an image gets `![name](path)`), to put into the task.
   */
  link?: string;
  writes?: number;
  to?: string;
  steps_ticked?: number;
  plans_closed?: string[];
  /**
   * The projects this finish closed after the plan (capability `projects`).
   */
  projects_closed?: string[];
  notes?: string[];
  move?: MovePlan;
  /**
   * `move_area`: the id the task has after the move.
   */
  new_id?: string;
  /**
   * `move_area`: the places that named the old id and now name the new one.
   */
  rewritten?: {
    kind: "blocked_by" | "after" | "refs" | "plan_target";
    id: string;
  }[];
}
/**
 * The operation that undoes a change: send it as a new operation (its `if_match` is the version the change left). A key the change added is `null` in the patch of a `set`.
 */
export interface Inverse {
  op:
    | "set"
    | "reorder"
    | "tick_step"
    | "answer"
    | "set_body"
    | "move_area"
    | "view_save"
    | "view_delete"
    | "plan_set"
    | "project_set";
  id: string;
  /**
   * `tick_step`: the number of the step.
   */
  n?: number;
  /**
   * `tick_step`: whether the step is to be ticked (true) or open (false).
   */
  done?: boolean;
  /**
   * `answer`: the key (`q1`) of the question.
   */
  question?: string;
  /**
   * `answer`: the option that was ticked.
   */
  option?: number;
  /**
   * `answer`: true when no option was ticked, the question was open.
   */
  clear?: boolean;
  /**
   * `set_body`: the text below the frontmatter that the task had.
   */
  body?: string;
  /**
   * `move_area`: the area the task came from (`id` is the id it has now).
   */
  to_area?: string;
  /**
   * `view_save`: the view as it was (a `view_save` with it puts it back).
   */
  view?: {};
  patch?: {};
  after?: string;
  before?: string;
  if_match?: Etag;
}
/**
 * Why an operation did not happen. `details` names ids, keys and values (`expected` and `actual` of a conflict, the `problems` of a refused relation), never a path.
 */
export interface OperationError {
  code: ErrorCode;
  message: string;
  retryable: boolean;
  details?: {};
}
/**
 * What moving a task to another area would do and break (stage 1 of `move_area`: a report, nothing is written).
 */
export interface MovePlan {
  new_id: string;
  to_area: string;
  from: string;
  to: string;
  folder: boolean;
  conflicts: {
    code: string;
    message: string;
  }[];
  /**
   * Places that name the old id and would dangle.
   */
  references: {
    kind: "blocked_by" | "after" | "plan_target" | "refs" | "document";
    id?: string;
    path?: string;
  }[];
  notes: string[];
}
