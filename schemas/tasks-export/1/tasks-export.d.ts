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
  | AgentAnswer
  | Next
  | Areas
  | Finished
  | History
  | Links
  | Groupings
  | Views
  | Waits
  | Find
  | Intent
  | Meetings
  | MeetingDocument
  | Paths
  | PathDocument
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
   * The day the engine counts as today: the local day of its machine (a `due:` or `remind:` day has come when it is this day or earlier). Additive.
   */
  today?: string;
  /**
   * The local time of day of the engine's machine, HH:MM, beside `today`: a caller without a time zone sends the reminders of the day from an hour of the person's choice. Additive.
   */
  time?: string;
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
    /**
     * The statuses of a meeting. Additive; capability `meetings`.
     */
    meeting_status?: string[];
    /**
     * The icons a meeting may name (`icon`). Additive; capability `meetings`. The same list as `icon_word`.
     */
    meeting_icon?: string[];
    /**
     * The words an `icon` of kind `word` may be (a front end draws its own sign for each). Additive; capability `icon`.
     */
    icon_word?: string[];
    /**
     * The services the address of a meeting is told as (`online_service`); `link` for any other. Additive; capability `meetings`.
     */
    online_service?: string[];
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
    remind_at?: string;
    /**
     * @maxItems 10
     */
    remind_to?:
      | []
      | [string]
      | [string, string]
      | [string, string, string]
      | [string, string, string, string]
      | [string, string, string, string, string]
      | [string, string, string, string, string, string]
      | [string, string, string, string, string, string, string]
      | [string, string, string, string, string, string, string, string]
      | [string, string, string, string, string, string, string, string, string]
      | [string, string, string, string, string, string, string, string, string, string];
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
    links?: PlanLinks;
    icon?: Icon;
    cover?: Cover;
    folder?: PlanFolder;
    assets?: PlanAssets;
    assets_truncated?: PlanAssetsTruncated;
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
    links?: PlanLinks;
    icon?: Icon;
    cover?: Cover;
    folder?: PlanFolder;
    assets?: PlanAssets;
    assets_truncated?: PlanAssetsTruncated;
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
 * The web addresses of a plan or project file (`links:`, http/https only; capability `plan_links`). Absent when it has none.
 */
export type PlanLinks = string[];
/**
 * A large picture of the item (`cover:`; capability `icon`): an image (png, jpg, jpeg, webp, svg) below `assets/` of its folder. Absent when it has none.
 */
export type Cover = string;
/**
 * The plan or project file is in its folder form (`<slug>/<slug>.md`, made by `attach` or `folderize`): the other files of that folder are its assets. Absent for a plain file.
 */
export type PlanFolder = true;
/**
 * The files in the folder of a plan or project (folder form only), relative to that folder (`assets/screenshots/shot.png`), sorted; at most 100.
 */
export type PlanAssets = string[];
/**
 * The folder holds more than the 100 `assets` listed.
 */
export type PlanAssetsTruncated = true;
/**
 * How a finished task ended beside `status: done` (capability `outcome`): learned, seen (looked at, not done) or not-applicable. Absent: done as meant.
 */
export type Outcome = "learned" | "seen" | "not-applicable";
/**
 * The learning point a task was promoted from: `<container id>#<key>`, the container a learning path or a task with `## Lernpunkte` (capability `outcome`).
 */
export type Point = string;
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
  /**
   * Capability task_finished: the call named finished, and this is the finished task of the id, read from its area's Backlog/ (no readiness, no rounds).
   */
  finished?: true;
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
 * tasks.agent_answer (capability agent_answer): the answer of an agent's job (kind review-done or prepare-decision) taken apart for one task by the rules of :Tasks agent, as the sections a caller writes with set_section after a yes. Nothing is written. The texts are untrusted.
 */
export type AgentAnswer = Head & {
  kind: "tasks.agent_answer";
  digest: Digest;
  answer_kind: "review-done" | "prepare-decision";
  /**
   * In the order to write them: the heading (one line, '## ' and a word) and the text below it, trimmed.
   *
   * @minItems 1
   * @maxItems 2
   */
  sections:
    | [
        {
          heading: string;
          text: string;
        }
      ]
    | [
        {
          heading: string;
          text: string;
        },
        {
          heading: string;
          text: string;
        }
      ];
  /**
   * review-done: the follow-up task the review proposes (create it only after a yes of its own).
   */
  follow_up?: {
    title: string;
    summary?: string;
  };
  /**
   * prepare-decision: whether the open questions are among the sections (only when the task has none of its own).
   */
  questions_added?: boolean;
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
 * tasks.history (capability `history`): the figures of the overview over time, one point per day or week of the window `since`..`until` (both included), oldest first. The levels come from the series the engine writes down below `_Telemetry/history/` of the vault (a row per day and area whose figures changed; `first` and `last` are the first and last day that has a row of the areas asked for, absent without a series). The series lies outside the revision, as the finished tasks do.
 */
export type History = Head & {
  kind: "tasks.history";
  digest: Digest;
  since: Date;
  until: Date;
  resolution: "day" | "week";
  /**
   * The area or area group asked for; absent for the whole vault.
   */
  area?: string;
  first?: Date;
  last?: Date;
  /**
   * @maxItems 800
   */
  points: HistoryPoint[];
  /**
   * What was skipped: a line of the series that is no row (`<file>:<line>: <why>`, relative to the vault), a folder that could not be read.
   */
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
      | "outcome"
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
 * tasks.meetings: the meetings whose days touch the window `since`..`until`, the earliest first, one page. Capability `meetings`.
 */
export type Meetings = Head & {
  kind: "tasks.meetings";
  rev: Rev;
  digest: Digest;
  since: Date;
  until: Date;
  area?: string;
  task?: string;
  total: number;
  offset: number;
  limit: number;
  next_offset?: number;
  /**
   * Meetings that match but have no valid date: in no window.
   */
  undated: number;
  items: MeetingEntry[];
  incomplete: string[];
};
/**
 * tasks.meeting: one meeting with its body and the sections the engine reads. Capability `meeting`.
 */
export type MeetingDocument = Head & {
  kind: "tasks.meeting";
  rev: Rev;
  digest: Digest;
  meeting: MeetingEntry;
  /**
   * The file after the frontmatter, untrusted text.
   */
  body: string;
  body_truncated: boolean;
  agenda: {
    n: number;
    text: string;
    ticked: boolean;
  }[];
  participants: {
    n: number;
    name: string;
    email?: string;
    role?: string;
    /**
     * Ticked in `## Teilnehmer`.
     */
    present: boolean;
  }[];
  documents: {
    n: number;
    text: string;
    kind: "web" | "asset" | "path" | "text";
    /**
     * The address, or the path below the meeting folder; a path of a machine is never named.
     */
    href?: string;
  }[];
  followups: {
    n: number;
    text: string;
    ticked: boolean;
    /**
     * The task made of the line (`-> <id>`).
     */
    task?: string;
  }[];
};
/**
 * tasks.paths: the open learning paths of the vault or of an area, each with its progress; no tree (that is tasks.path). Capability `paths`.
 */
export type Paths = Head & {
  kind: "tasks.paths";
  rev: Rev;
  digest: Digest;
  items: PathEntry[];
  incomplete: string[];
};
/**
 * tasks.path: one learning path with its body and its tree as a flat list in document order. Capability `path`.
 */
export type PathDocument = Head & {
  kind: "tasks.path";
  rev: Rev;
  digest: Digest;
  path: PathEntry;
  /**
   * The file after the frontmatter, untrusted text.
   */
  body: string;
  body_truncated: boolean;
  nodes: PathNode[];
  progress: PathProgress;
  tree_problems: {
    code: string;
    line: number;
    key?: string;
    message: string;
  }[];
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
  outcome?: Outcome;
  /**
   * Why it ended so (required by the engine for `seen` and `not-applicable`). Capability `outcome`.
   */
  outcome_reason?: string;
  point?: Point;
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
 * What an item stands for (`icon:`; capability `icon`): an emoji (one grapheme cluster), an image below `assets/` of the item's folder, or a word of `hello.enums.icon_word`. Absent when the item has none.
 */
export interface Icon {
  kind: "emoji" | "asset" | "word";
  value: string;
}
/**
 * One task. A broken task is still here (`valid: false`, `problems`); a field that is missing is unknown, never 0 (no `effort` means no `effort_days` and no `roi`).
 */
export interface TaskEntry {
  /**
   * The meetings that name the task (`tasks:` of a meeting file), the earliest first, at most 20. Only when there are some. Additive; capability `meetings`.
   *
   * @maxItems 20
   */
  meetings?:
    | []
    | [string]
    | [string, string]
    | [string, string, string]
    | [string, string, string, string]
    | [string, string, string, string, string]
    | [string, string, string, string, string, string]
    | [string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string, string, string, string, string, string, string]
    | [
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string
      ]
    | [
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string
      ]
    | [
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string
      ]
    | [
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string
      ]
    | [
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string
      ]
    | [
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string,
        string
      ];
  /**
   * The task has more meetings than `meetings` names.
   */
  meetings_truncated?: true;
  outcome?: Outcome;
  /**
   * Why it ended so (required by the engine for `seen` and `not-applicable`). Capability `outcome`.
   */
  outcome_reason?: string;
  point?: Point;
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
   * The local time of day (HH:MM) the reminder of the `remind` day is sent; only beside `remind`. Without it the reminder goes with the notice of the day. Additive.
   */
  remind_at?: string;
  /**
   * The e-mail addresses the reminder of the `remind` day is sent to (only valid ones, only beside `remind`). Additive.
   *
   * @maxItems 10
   */
  remind_to?:
    | []
    | [string]
    | [string, string]
    | [string, string, string]
    | [string, string, string, string]
    | [string, string, string, string, string]
    | [string, string, string, string, string, string]
    | [string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string, string, string];
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
  icon?: Icon;
  cover?: Cover;
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
    claimed?: string;
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
 * One open plan of tasks.plan_compare. `tasks`: its open and finished tasks, the open ones by readiness state. `effort`: open days (with the range of the sizes), finished days, open tasks without an effort. `path`: the critical path of the plan's open tasks alone (a blocker outside the plan takes no part). `weekly_done`: members finished in each of the last `weeks` weeks, oldest first (the last week ends `today`). `forecast_weeks`: weeks the open tasks would still take, `low` at the pace of the best of those weeks, `high` at their average; absent when nothing was finished in them or nothing is open. `phase_now`: the first stage of the plan's `phase_order` that still has an open task. `value`: over the open tasks, the sum of their `value`, the average of those that carry one (two decimals, absent when none does) and how many carry none; `prio`: the best (lowest) prio among them. `areas`: the plan's own area, then the other areas it names (a plan that names none is one of its own area). `target_due`: the `due` of the plan's `target` task while it is open, `due_in_days` from `today` (negative when it has passed), and `forecast_late`: `forecast_weeks.high` weeks from `today` end after that day (only with both a due day and a forecast).
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
  areas?: string[];
  value?: {
    sum: number;
    avg?: number;
    without: number;
  };
  prio?: number;
  target?: string;
  target_due?: Date;
  due_in_days?: number;
  forecast_late?: boolean;
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
  outcome?: Outcome;
  /**
   * Why it ended so (required by the engine for `seen` and `not-applicable`). Capability `outcome`.
   */
  outcome_reason?: string;
  point?: Point;
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
 * One day (or one week, named by its Monday) of `tasks.history`. `done` and `created` are what the files say about the day and are always there. The level (`open` and the fields beside it) is the sum over the areas of the last row each of them has up to that day: absent before the first row (unknown, never 0), all of it or none. `recorded` is false for a level that was carried over (no row of the areas asked for was written on that day).
 */
export interface HistoryPoint {
  day: Date;
  recorded: boolean;
  /**
   * Tasks finished on the day (the date in the name of the Backlog file); for a week their sum.
   */
  done: number;
  /**
   * Tasks, open or finished, whose `created` is the day; for a week their sum.
   */
  created: number;
  /**
   * Open tasks.
   */
  open?: number;
  by_status?: {
    [k: string]: number;
  };
  /**
   * By readiness, the figures of the plan head of the snapshot (`plan.summary`).
   */
  by_state?: {
    ready: number;
    decision: number;
    waiting: number;
    stuck: number;
    freed: number;
    parked: number;
  };
  /**
   * Open tasks that carry an effort.
   */
  with_effort?: number;
  /**
   * Open tasks that carry a value.
   */
  with_value?: number;
  /**
   * The sum of the written efforts of the open tasks.
   */
  effort_days?: number;
  /**
   * The sum of the written values of the open tasks.
   */
  value?: number;
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
 * A task that names a ref: the ref, the task (id, area, status) and where it is, `open` (ROADMAP) or `done` (Backlog). Never a path. A meeting (`kind` `meeting`, capability `meeting_ops`) matches a task id it names in `tasks:` or behind a follow-up; it is `open` while planned.
 */
export interface FindMatch {
  ref: string;
  id: string;
  area: string;
  status: string;
  location: "open" | "done";
  kind?: "task" | "meeting";
}
/**
 * One meeting (`<area>/MEETINGS/<slug>.md`). A broken meeting is still here (`valid: false`, `problems`); a field that is missing is unknown. Nothing changes with the day: whether a meeting is past is for the reader to say from `starts_at` and `ends_at` (local wall time, or the time of `tz`).
 */
export interface MeetingEntry {
  id: string;
  area: string;
  slug: string;
  title: string;
  /**
   * Absent for a file with no valid status.
   */
  status?: "planned" | "done" | "cancelled";
  date?: Date;
  /**
   * The beginning; absent: all day.
   */
  time?: string;
  /**
   * The end as written (`end:`), when the file names one.
   */
  end?: string;
  /**
   * From `duration`, or from `time` and `end`.
   */
  duration_min?: number;
  /**
   * Only beside a valid date.
   */
  all_day?: boolean;
  /**
   * `YYYY-MM-DDTHH:MM`, or the day of an all-day meeting.
   */
  starts_at?: string;
  /**
   * The end in the same form (an all-day meeting: its last day).
   */
  ends_at?: string;
  /**
   * An IANA time zone the times are written in (only its form is checked).
   */
  tz?: string;
  location?: string;
  online?: string;
  online_service?: "teams" | "zoom" | "meet" | "webex" | "jitsi" | "link";
  tasks: string[];
  notify: {
    spec: string;
    before_min?: number;
    days_before?: number;
    at?: string;
  }[];
  /**
   * @maxItems 10
   */
  notify_to?:
    | []
    | [string]
    | [string, string]
    | [string, string, string]
    | [string, string, string, string]
    | [string, string, string, string, string]
    | [string, string, string, string, string, string]
    | [string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string, string]
    | [string, string, string, string, string, string, string, string, string, string];
  /**
   * The old name of `cover`, kept for the readers of before: the same value.
   */
  image?: string;
  cover?: Cover;
  icon?: Icon;
  tags: string[];
  recording?: string;
  created?: Date;
  updated?: Date;
  summary: string;
  participants: {
    total: number;
    present?: number;
    ticked?: number;
  };
  agenda: {
    total: number;
    present?: number;
    ticked?: number;
  };
  followups: {
    total: number;
    present?: number;
    ticked?: number;
  };
  has_result: boolean;
  has_decisions: boolean;
  has_protocol: boolean;
  folder?: true;
  assets?: PlanAssets;
  assets_truncated?: PlanAssetsTruncated;
  file: string;
  etag?: Etag;
  valid: boolean;
  problems: Problem[];
}
/**
 * A learning path (`<area>/ROADMAP/paths/<slug>.md`): the head of its file, its progress over the leaves of its tree, its version.
 */
export interface PathEntry {
  id: string;
  area: string;
  slug: string;
  title: string;
  status?: "planning" | "doing" | "parked" | "done";
  areas: string[];
  target?: string;
  project?: string;
  created?: Date;
  updated?: Date;
  summary: string;
  /**
   * The file has a `## Lernpunkte` section.
   */
  has_tree: boolean;
  /**
   * The learning points of the tree, parents included.
   */
  points: number;
  progress: PathProgress;
  links?: string[];
  icon?: Icon;
  cover?: Cover;
  folder?: boolean;
  assets?: PlanAssets;
  assets_truncated?: PlanAssetsTruncated;
  file: string;
  etag?: Etag;
  valid: boolean;
  problems: string[];
}
/**
 * Progress over leaves, counted apart: learned, seen, dropped, open (blocked ones counted as open and once more as blocked).
 */
export interface PathProgress {
  learned: number;
  seen: number;
  dropped: number;
  open: number;
  blocked: number;
  total: number;
}
/**
 * One learning point of a tree. A parent has no mark of its own: its `derived` state comes from its leaves (learned, partial, open); `closed` when every leaf is.
 */
export interface PathNode {
  /**
   * Position in document order; `#<index>` names the point where it has no key.
   */
  index: number;
  /**
   * The line of the body it stands on.
   */
  line: number;
  depth: number;
  /**
   * The `index` of its parent; absent for a root.
   */
  parent?: number;
  children: number;
  mark: string;
  /**
   * Absent for an unknown mark (a tree problem).
   */
  state?: "open" | "learned" | "seen" | "dropped" | "blocked";
  derived: "open" | "learned" | "seen" | "dropped" | "blocked" | "partial";
  closed: boolean;
  /**
   * As written (Markdown, untrusted).
   */
  label: string;
  key?: string;
  reason?: string;
  /**
   * The task the point was promoted to; it owns the point's state.
   */
  promoted?: string;
  link?: string;
  /**
   * A file below `assets/` of the path; a client draws it as an image only.
   */
  image?: string;
  note?: string;
  progress: PathProgress;
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
    | "set_section"
    | "view_save"
    | "view_delete"
    | "attach"
    | "claim"
    | "release"
    | "history_record"
    | "meeting_new"
    | "meeting_set"
    | "meeting_close"
    | "meeting_capture"
    | "meeting_attend"
    | "meeting_followups"
    | "board_save"
    | "path_new"
    | "path_set"
    | "path_close"
    | "node_set"
    | "promote"
    | "unpromote";
  id?: string;
  /**
   * `meeting_close`: the meeting has no `## Ergebnis` afterwards (allowed: a hint for the front end).
   */
  without_result?: boolean;
  /**
   * `meeting_followups`: one entry per follow-up line it worked on: the task made of it (`id`) or why not (`error`).
   */
  items?: {
    n: number;
    ok: boolean;
    id?: string;
    error?: string;
    note?: string;
  }[];
  /**
   * `board_save`: the preview of the board below its folder (`assets/boards/<name>.svg`).
   */
  preview?: string;
  /**
   * The version of a file: `sha256:` and 16 hex digits of the hash of its bytes.
   */
  etag?: string;
  /**
   * `board_save`: true when the board was new, false when it replaced one.
   */
  created?: boolean;
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
    | "removed"
    | "would_remove"
    | "blocked"
    | "failed";
  /**
   * `node_set`: the learning point as it is now (capability `node_set`).
   */
  node?: {
    line: number;
    key?: string;
    state: "open" | "learned" | "seen" | "dropped" | "blocked";
  };
  progress?: PathProgress1;
  /**
   * The learning point a task was promoted from: `<container id>#<key>`, the container a learning path or a task with `## Lernpunkte` (capability `outcome`).
   */
  promoted_from?: string;
  /**
   * `promote`: the lines of the point's subtree that moved into the task.
   */
  moved?: number;
  /**
   * `promote`, `unpromote`: the open tasks of points promoted below the moved one, whose `point` now names the new container.
   */
  repointed?: string[];
  /**
   * `unpromote`: the path or task the point is in.
   */
  container?: string;
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
  /**
   * `history_record`: the rows written into the series (a dry run: that would be written).
   */
  rows?: number;
  to?: string;
  steps_ticked?: number;
  plans_closed?: string[];
  /**
   * The projects this finish closed after the plan (capability `projects`).
   */
  projects_closed?: string[];
  /**
   * `done`: the learning point the task was promoted from, set to the state of the finish (capability `outcome`).
   */
  point?: {
    container: string;
    key: string;
    state: "open" | "learned" | "seen" | "dropped" | "blocked";
    changed: boolean;
  };
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
    kind: "blocked_by" | "after" | "refs" | "plan_target" | "meeting";
    id: string;
  }[];
}
/**
 * Progress over leaves, counted apart: learned, seen, dropped, open (blocked ones counted as open and once more as blocked).
 */
export interface PathProgress1 {
  learned: number;
  seen: number;
  dropped: number;
  open: number;
  blocked: number;
  total: number;
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
    | "set_section"
    | "move_area"
    | "view_save"
    | "view_delete"
    | "plan_set"
    | "project_set"
    | "meeting_set"
    | "meeting_attend"
    | "path_set"
    | "node_set"
    | "unpromote";
  /**
   * `unpromote`: the path or task the learning point is in.
   */
  container?: string;
  /**
   * `node_set`, `unpromote`: the learning point, its key or `#<index>`.
   */
  point?: string;
  /**
   * `node_set`: the state the point had.
   */
  state?: "open" | "learned" | "seen" | "dropped" | "blocked";
  /**
   * `node_set`: the reason the point had.
   */
  reason?: string;
  /**
   * `tick_step` of a meeting: the section of the item (`agenda`, `followups`).
   */
  section?: "agenda" | "followups";
  /**
   * `meeting_attend`: the participant, by name.
   */
  name?: string;
  /**
   * `meeting_attend`: whether the participant is to be ticked present.
   */
  present?: boolean;
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
   * `set_section`: the heading of the section that was replaced.
   */
  heading?: string;
  /**
   * `set_section`: the text the section had below its heading.
   */
  text?: string;
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
 * Why an operation did not happen. `details` names ids, keys and values (`expected` and `actual` of a conflict, the `problems` of a refused relation, `field`/`value`/`char`/`suggestion` of a word that is no kebab-case word), never a path.
 */
export interface OperationError {
  code: ErrorCode;
  message: string;
  retryable: boolean;
  details?: {
    /**
     * A word that must be kebab-case (a phase, an entry of the phases) was not: the field it was given for (`phase`).
     */
    field?: string;
    /**
     * The word as it was given.
     */
    value?: string;
    /**
     * The first character that is not allowed (`-` when the hyphens are wrong); absent for an empty word.
     */
    char?: string;
    /**
     * A word that would do: umlauts and ß written out (`ü` -> `ue`), lower case, other characters as single hyphens. Absent when nothing usable is left.
     */
    suggestion?: string;
  };
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
    kind: "blocked_by" | "after" | "plan_target" | "refs" | "document" | "meeting";
    id?: string;
    path?: string;
  }[];
  notes: string[];
}
