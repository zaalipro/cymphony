let meta = #{
    name: "cymphony-next-level",
    description: "One-shot heavy upgrade: Antigravity agent support, Codex hardening, next-level dashboard monitoring with harness/model/reasoning controls, and live harness output streaming",
    when_to_use: "Execute the full Cymphony next-level upgrade in one shot (~48 agents, budget 50). Optional args.notes: extra instructions injected into planning.",
    phases: [
        #{ title: "Explore", detail: "6 read-only scouts inventory adapters, config/CLI, dashboard, streaming, tests, providers" },
        #{ title: "Plan", detail: "1 architect produces <= 26 work packages with exclusive file ownership" },
        #{ title: "Implement", detail: "parallel work packages, disjoint files, no builds" },
        #{ title: "Integrate", detail: "compile, format, stitch cross-package seams" },
        #{ title: "Stabilize", detail: "gate + fix loop, max 3 rounds" },
        #{ title: "Verify", detail: "6 parallel verifiers including the full make-all gate" },
        #{ title: "Report", detail: "assemble final report" },
    ],
};

// ---------- schemas ----------

let scout_schema = #{
    "type": "object", "required": ["summary", "facts"],
    "properties": #{
        "summary": #{ "type": "string" },
        "facts": #{ "type": "array", "maxItems": 20, "items": #{ "type": "string" } },
    },
};

let plan_schema = #{
    "type": "object", "required": ["contract", "work_packages"],
    "properties": #{
        "contract": #{ "type": "string" },
        "work_packages": #{
            "type": "array", "minItems": 8, "maxItems": 26,
            "items": #{
                "type": "object", "required": ["id", "title", "goal", "files", "instructions"],
                "properties": #{
                    "id": #{ "type": "string" },
                    "title": #{ "type": "string" },
                    "goal": #{ "type": "string" },
                    "files": #{ "type": "array", "items": #{ "type": "string" } },
                    "instructions": #{ "type": "string" },
                    "verify": #{ "type": "string" },
                },
            },
        },
    },
};

let impl_schema = #{
    "type": "object", "required": ["status", "files_changed"],
    "properties": #{
        "status": #{ "type": "string" },
        "files_changed": #{ "type": "array", "maxItems": 40, "items": #{ "type": "string" } },
        "cross_package_notes": #{ "type": "string" },
    },
};

let gate_schema = #{
    "type": "object", "required": ["clean", "errors"],
    "properties": #{
        "clean": #{ "type": "boolean" },
        "errors": #{ "type": "string" },
    },
};

let verify_schema = #{
    "type": "object", "required": ["passed", "evidence", "problems"],
    "properties": #{
        "passed": #{ "type": "boolean" },
        "evidence": #{ "type": "string" },
        "problems": #{ "type": "array", "maxItems": 10, "items": #{ "type": "string" } },
    },
};

// ---------- helpers ----------

fn s(x) { if type_of(x) == "string" { x } else { "" } }

fn get_str(m, key) {
    if m != () && type_of(m) == "map" && m.contains(key) && type_of(m[key]) == "string" { m[key] } else { "" }
}

fn get_bool(m, key) {
    if m != () && type_of(m) == "map" && m.contains(key) && type_of(m[key]) == "bool" { m[key] } else { false }
}

fn get_arr(m, key) {
    if m != () && type_of(m) == "map" && m.contains(key) && type_of(m[key]) == "array" { m[key] } else { [] }
}

const MAX_PACKAGES = 26;
const MAX_STABILIZE_ROUNDS = 3;

// ---------- args ----------

let notes = "";
if args != () && type_of(args) == "map" && args.contains("notes") && type_of(args.notes) == "string" {
    notes = args.notes;
}

// ---------- shared context strings ----------

let CONVENTIONS = "";
CONVENTIONS += "Repo conventions (mandatory): Elixir 1.19/OTP 28 escript OTP app (Cymphony: polls Linear and runs coding-agent CLIs headlessly; Phoenix LiveView dashboard). ";
CONVENTIONS += "Every public def in lib/ needs an adjacent @spec (enforced by mix specs.check); @impl callbacks exempt, defp specs optional. ";
CONVENTIONS += "Compile regexes at runtime with Regex.compile!/1, never sigils. ";
CONVENTIONS += "Never read env vars directly in business logic; go through CymphonyElixir.Config. ";
CONVENTIONS += "Workspace safety: agent CLIs must never run with cwd inside the source repo; workspaces stay under the configured root. ";
CONVENTIONS += "Follow existing module/style patterns in lib/cymphony_elixir/*. Tests under test/ mirror lib paths. ";
CONVENTIONS += "The working tree already contains uncommitted dashboard-overhaul changes: extend them, never revert them. ";
CONVENTIONS += "If behavior/config changes, docs must be updated too (SPEC.md, README.md, WORKFLOW.md, and the Claude.md/Agents.md sections that describe them).";

let GOALS = "";
GOALS += "G1 ANTIGRAVITY AGENT: Add Antigravity (Google's agentic coding CLI) as a third coding-agent kind end to end: ";
GOALS += "an Agent.Antigravity adapter under lib/cymphony_elixir/agent/ implementing the existing CymphonyElixir.Agent behaviour exactly like agent/codex.ex does ";
GOALS += "(argv construction, output parsing, session resume), config schema support (agent.kind=antigravity plus a config.antigravity.* section in config/schema.ex), ";
GOALS += "CLI shorthand 'agent antigravity' in cli.ex, per-issue label/directive support (agent:antigravity via run_spec_resolver.ex), ";
GOALS += "provider env-var prefix support in cymphony/shell_provider.ex, agent_catalog.ex registration, tests mirroring the Codex adapter tests, and doc updates. ";
GOALS += "G2 CODEX HARDENING: close any gaps the scouts find in the existing Codex path (model/effort pass-through, resume, JSONL event parsing, provider env capture). ";
GOALS += "G3 DASHBOARD MONITORING: take the LiveView dashboard (lib/cymphony_elixir_web/live/dashboard_live.ex) to the next level: richer metric tiles, ";
GOALS += "per-session token rates, state breakdowns, sparkline history, and better session detail, building on the uncommitted dashboard-overhaul work. ";
GOALS += "G4 HARNESS/MODEL/REASONING CONTROLS: dashboard customization of harness (claude/codex/antigravity), model (with per-kind suggestions), and reasoning effort ";
GOALS += "at both project level and per running session, wired through the existing LiveView events and runtime APIs, persisted to config where existing patterns persist. ";
GOALS += "G5 HARNESS STREAMING: show a live stream of each session's harness (agent CLI) output in the dashboard: ";
GOALS += "Agent.Runner port output -> bounded per-session ring buffer -> ObservabilityPubSub -> LiveView tail pane with autoscroll. Must be backpressure-safe and must not flood the LiveView.";

// ---------- Phase 1: Explore ----------

phase("Explore");
log("Scouting the codebase with 6 read-only agents");

let scout_jobs = [];

let p1 = "";
p1 += "You are scouting the Cymphony Elixir repo. Use read_file, list_dir, and grep to inspect the ACTUAL code before answering; never answer from memory. ";
p1 += "Inventory the coding-agent adapter layer: lib/cymphony_elixir/agent.ex (behaviour), lib/cymphony_elixir/agent/runner.ex (shared port machinery), ";
p1 += "lib/cymphony_elixir/agent/claude.ex, lib/cymphony_elixir/agent/codex.ex, and lib/cymphony_elixir/agent_catalog.ex. ";
p1 += "Report the exact behaviour callbacks and their @spec signatures, how each adapter builds argv, how stdout/JSONL is parsed into events, ";
p1 += "how session resume works, where env vars are injected, and precisely what a brand-new third adapter (Antigravity) must implement. ";
p1 += "facts must be concrete file-level findings (module names, callback names, function names), not generalities.";
scout_jobs.push(#{ prompt: p1, label: "scout-adapters", agent_type: "explore", capability_mode: "read-only", output_schema: scout_schema });

let p2 = "";
p2 += "You are scouting the Cymphony Elixir repo. Use read_file, list_dir, and grep to inspect the ACTUAL code before answering; never answer from memory. ";
p2 += "Inventory config and CLI handling of agent kinds: lib/cymphony_elixir/config.ex, lib/cymphony_elixir/config/schema.ex, lib/cymphony_elixir/cli.ex, ";
p2 += "lib/cymphony_elixir/cymphony/config.ex, lib/cymphony_elixir/run_spec_resolver.ex. ";
p2 += "Report: where agent kind values (claude/codex) are validated or enumerated, how model/effort are passed through to the agent CLI, ";
p2 += "how per-issue labels/directives (agent:, model:, effort:, provider:) resolve, how 'agent <kind>' CLI shorthand expands, ";
p2 += "and every place a new kind value 'antigravity' would need to be added. facts must be concrete file-level findings.";
scout_jobs.push(#{ prompt: p2, label: "scout-config-cli", agent_type: "explore", capability_mode: "read-only", output_schema: scout_schema });

let p3 = "";
p3 += "You are scouting the Cymphony Elixir repo. Use read_file, list_dir, and grep to inspect the ACTUAL code before answering; never answer from memory. ";
p3 += "Inventory the Phoenix LiveView dashboard: lib/cymphony_elixir_web/live/dashboard_live.ex, lib/cymphony_elixir_web/components/layouts.ex, ";
p3 += "lib/cymphony_elixir_web/router.ex, priv/static/dashboard.css and any related JS/CSS assets. ";
p3 += "Report: current monitoring surfaces (metric tiles, sparklines, session rows, expanded session detail, settings drawer), ";
p3 += "the per-project controls (agent select, model input, effort select, providers input), the full list of handle_event handlers relevant to ";
p3 += "run-spec overrides and project settings, and how the LiveView receives orchestrator updates (pubsub subscribe topics, tick timers). ";
p3 += "facts must be concrete findings (event names, assigns, DOM ids/classes), not generalities.";
scout_jobs.push(#{ prompt: p3, label: "scout-dashboard", agent_type: "explore", capability_mode: "read-only", output_schema: scout_schema });

let p4 = "";
p4 += "You are scouting the Cymphony Elixir repo. Use read_file, list_dir, and grep to inspect the ACTUAL code before answering; never answer from memory. ";
p4 += "Trace where agent-CLI process output goes today: lib/cymphony_elixir/agent/runner.ex port output handling, log event emission, ";
p4 += "the ObservabilityPubSub module (grep for its name), any per-session log-event buffer, lib/cymphony_elixir/status_dashboard.ex, ";
p4 += "and what the dashboard currently shows in expanded session rows (recent log events). ";
p4 += "Report the exact data path from port stdout to dashboard, what storage/buffering exists, and what is missing for a live streaming tail pane. ";
p4 += "facts must be concrete findings (module/function names, message shapes, pubsub topics).";
scout_jobs.push(#{ prompt: p4, label: "scout-streaming", agent_type: "explore", capability_mode: "read-only", output_schema: scout_schema });

let p5 = "";
p5 += "You are scouting the Cymphony Elixir repo. Use read_file, list_dir, and grep to inspect the ACTUAL files before answering; never answer from memory. ";
p5 += "Inventory tests and CI: the test/ directory layout, adapter/extension tests (e.g. test/cymphony_elixir/extensions_test.exs and any codex/claude adapter tests), ";
p5 += "the Makefile targets (test, coverage, lint, fmt-check, dialyzer, all), coverage configuration and its threshold policy for tracked modules, ";
p5 += "and .github/workflows (make-all.yml). Report what a feature adding a new lib module must do to pass 'make all' (tests, @spec, formatting, credo, coverage, dialyzer). ";
p5 += "facts must be concrete findings (file paths, config keys, thresholds).";
scout_jobs.push(#{ prompt: p5, label: "scout-tests-ci", agent_type: "explore", capability_mode: "read-only", output_schema: scout_schema });

let p6 = "";
p6 += "You are scouting the Cymphony Elixir repo. Use read_file, list_dir, and grep to inspect the ACTUAL code before answering; never answer from memory. ";
p6 += "Inventory the provider system: lib/cymphony_elixir/cymphony/shell_provider.ex (env-var prefixes captured per agent kind, e.g. ANTHROPIC_*/CLAUDE_CODE_* for Claude ";
p6 += "and OPENAI_*/CODEX_* for Codex), lib/cymphony_elixir/orchestrator.ex provider selection, and provider config in cymphony/config.ex. ";
p6 += "Report exactly what a new agent kind needs to participate in provider rotation and shell-provider env capture. facts must be concrete findings.";
scout_jobs.push(#{ prompt: p6, label: "scout-providers", agent_type: "explore", capability_mode: "read-only", output_schema: scout_schema });

let scout_results = parallel(scout_jobs);

let scout_names = ["adapters", "config-cli", "dashboard", "streaming", "tests-ci", "providers"];
let inventory = "";
let si = 0;
for r in scout_results {
    let name = scout_names[si];
    if r != () && r.success && type_of(r.output) == "map" {
        inventory += "## Scout: " + name + "\n" + get_str(r.output, "summary") + "\n";
        let facts = get_arr(r.output, "facts");
        for f in facts { inventory += "- " + s(f) + "\n"; }
    } else {
        inventory += "## Scout: " + name + "\n(scout failed - planner must re-verify this area by reading the code itself)\n";
    }
    si += 1;
}

// ---------- Phase 2: Plan ----------

phase("Plan");
log("Architect is producing disjoint work packages");

let plan_prompt = "";
plan_prompt += "You are the software architect for a one-shot heavy upgrade of the Cymphony Elixir repo (working tree: the repo root). ";
plan_prompt += "Six scout reports about the current code follow below; verify anything you rely on by reading the actual files with read_file/grep (you are read-only). ";
if notes != "" { plan_prompt += "EXTRA INSTRUCTIONS FROM THE USER: " + notes + ". "; }
plan_prompt += "Deliver a plan as JSON matching the required schema.\n\n";
plan_prompt += "GOALS:\n" + GOALS + "\n\n";
plan_prompt += "Antigravity specifics: Antigravity is Google's agentic coding product with a CLI that supports headless runs. Use web_search if available ";
plan_prompt += "(try 'Antigravity CLI headless run', 'Google Antigravity agent CLI') to pin down its binary name, headless/exec flags, JSON output, and resume semantics. ";
plan_prompt += "If documentation is inconclusive, design the adapter conservatively modeled on agent/codex.ex with a configurable binary and args template ";
plan_prompt += "(config keys under config.antigravity.* such as binary and extra_args) and record the assumptions in the contract. ";
plan_prompt += "Env-var prefixes for shell-provider capture should follow the existing pattern (likely ANTIGRAVITY_*/GOOGLE_*/GEMINI_*).\n\n";
plan_prompt += "PLANNING RULES:\n";
plan_prompt += "1. Produce between 10 and 26 work_packages (target ~20). Each package must be completable by one engineer-agent writing files only.\n";
plan_prompt += "2. Every package has a 'files' list: ALL files it will create or modify (lib, test, docs, css/js assets). File lists MUST be mutually exclusive across packages - no file in two packages.\n";
plan_prompt += "3. Hotspot files that several goals touch (dashboard_live.ex, layouts.ex, router.ex, cli.ex, schema.ex, orchestrator.ex, shell_provider.ex, agent/runner.ex) must belong to exactly ONE package each; other packages that need changes there will file cross-package notes at implementation time, and the contract must define clear extension points so those notes stay small.\n";
plan_prompt += "4. Include test files in the owning package, and include exactly one docs package that updates SPEC.md, README.md, WORKFLOW.md and the Claude.md/Agents.md sections to match the new behavior.\n";
plan_prompt += "5. The 'contract' string is the single source of truth every implementer codes against: new module names and @spec signatures, behaviour callbacks for the Antigravity adapter, config keys, CLI tokens, message/event shapes, pubsub topics, ring-buffer API, DOM ids/classes and LiveView event names for the dashboard, and cross-package extension points. Be precise and complete.\n";
plan_prompt += "6. Balance package sizes (none more than ~3x another). New lib modules need tests because the coverage gate is strict.\n";
plan_prompt += "7. Do not plan edits under _build, deps, or .git.\n\n";
plan_prompt += "SCOUT REPORTS:\n" + inventory;

let plan = agent(plan_prompt, #{ label: "architect", capability_mode: "read-only", output_schema: plan_schema });

if plan == () || !plan.success || type_of(plan.output) != "map" {
    complete(#{ summary: "Planning failed; nothing implemented.", passed: false });
}

let contract = get_str(plan.output, "contract");
let raw_packages = get_arr(plan.output, "work_packages");
if contract == "" || raw_packages.len() == 0 {
    complete(#{ summary: "Planner returned no usable contract/work packages.", passed: false });
}

// Enforce exclusive file ownership; drop duplicate ownership from later packages.
let owned = #{};
let packages = [];
let dropped_files = 0;
for p0 in raw_packages {
    if packages.len() >= MAX_PACKAGES {
        log("Dropping package beyond MAX_PACKAGES: " + get_str(p0, "id"));
    } else if type_of(p0) == "map" {
        let kept = [];
        let fs = get_arr(p0, "files");
        for f in fs {
            let ff = s(f);
            if ff != "" {
                if owned.contains(ff) {
                    dropped_files += 1;
                } else {
                    owned[ff] = get_str(p0, "id");
                    kept.push(ff);
                }
            }
        }
        packages.push(#{
            id: get_str(p0, "id"),
            title: get_str(p0, "title"),
            goal: get_str(p0, "goal"),
            instructions: get_str(p0, "instructions"),
            verify: get_str(p0, "verify"),
            files: kept,
        });
    }
}
if dropped_files > 0 {
    log("Ownership enforcement removed " + dropped_files.to_string() + " duplicate file assignments from later packages");
}
if packages.len() == 0 {
    complete(#{ summary: "No work packages survived filtering.", passed: false });
}

// ---------- Phase 3: Implement ----------

phase("Implement");
log("Fanning out " + packages.len().to_string() + " implementation agents");

let impl_jobs = [];
for pkg in packages {
    let prompt = "";
    prompt += "You are one of " + packages.len().to_string() + " implementation agents working CONCURRENTLY in the same working tree of the Cymphony Elixir repo. ";
    prompt += "HARD RULES: (1) Only create or modify the files listed in YOUR FILES below; every other file is owned by another concurrent agent. If you believe a change is needed elsewhere, do NOT make it - record it in cross_package_notes instead. ";
    prompt += "(2) You have no shell: do not attempt mix/make/git commands. Read the surrounding modules first and write code carefully; a later integration agent compiles and stitches. ";
    prompt += "(3) Write or extend tests for your change inside your owned test files. ";
    prompt += "(4) Never revert the uncommitted dashboard-overhaul changes already in the working tree.\n";
    prompt += CONVENTIONS + "\n\n";
    prompt += "SHARED CONTRACT (code exactly against these interfaces; other agents rely on them):\n" + contract + "\n\n";
    prompt += "YOUR PACKAGE id=" + pkg.id + " | title=" + pkg.title + "\n";
    prompt += "GOAL: " + pkg.goal + "\n";
    prompt += "INSTRUCTIONS:\n" + pkg.instructions + "\n";
    if pkg.verify != "" { prompt += "ACCEPTANCE HINT: " + pkg.verify + "\n"; }
    prompt += "YOUR FILES:\n";
    for f in pkg.files { prompt += "- " + f + "\n"; }
    prompt += "\nReport: status (one short sentence), files_changed (every path you created or edited), cross_package_notes (changes needed in files you do not own; empty string if none).";
    impl_jobs.push(#{ prompt: prompt, label: "impl-" + pkg.id, capability_mode: "read-write", output_schema: impl_schema });
}

let impl_results = parallel(impl_jobs);

let xnotes = "";
let impl_ok = 0;
for r in impl_results {
    if r != () && r.success && type_of(r.output) == "map" {
        impl_ok += 1;
        let n = get_str(r.output, "cross_package_notes");
        if n != "" { xnotes += "- " + n + "\n"; }
    }
}
log("Implementation done: " + impl_ok.to_string() + "/" + packages.len().to_string() + " packages reported success");

// ---------- Phase 4: Integrate ----------

phase("Integrate");

let int_prompt = "";
int_prompt += "You are the integration agent for the Cymphony Elixir repo. " + packages.len().to_string() + " concurrent agents just implemented work packages in this working tree without compiling. ";
int_prompt += "Make it compile and cohere. Steps: (1) run 'mix compile' and fix every error, anywhere in the tree. (2) run 'mix format'. (3) run 'mix specs.check' and add any missing @spec. ";
int_prompt += "(4) Apply the CROSS-PACKAGE NOTES below - these are changes package agents needed in files they did not own; implement them consistent with the contract. ";
int_prompt += "Keep fixes minimal. Do not run the full test suite yet. " + CONVENTIONS + "\n\n";
int_prompt += "SHARED CONTRACT:\n" + contract + "\n\n";
int_prompt += "CROSS-PACKAGE NOTES:\n";
if xnotes == "" { int_prompt += "(none reported)\n"; } else { int_prompt += xnotes; }

let integ = agent(int_prompt, #{ label: "integrate", capability_mode: "execute" });
if integ == () || !integ.success {
    log("Integration agent failed; stabilize loop must recover from here");
}

// ---------- Phase 5: Stabilize ----------

phase("Stabilize");

let stable = false;
let round = 0;
while !stable && round < MAX_STABILIZE_ROUNDS {
    round += 1;
    let gate_prompt = "";
    gate_prompt += "You are a build gate for the Cymphony Elixir repo. Run these commands in order and stop at the first one that fails: ";
    gate_prompt += "(1) mix compile (2) mix format --check-formatted (3) mix specs.check (4) mix test. ";
    gate_prompt += "If ALL pass: clean=true, errors=''. Otherwise clean=false and errors = the failing command name plus the most relevant error excerpts (cap ~6000 chars). ";
    gate_prompt += "Do NOT fix anything; only measure and report.";
    let gate = agent(gate_prompt, #{ label: "gate-" + round.to_string(), capability_mode: "execute", output_schema: gate_schema });
    if gate != () && gate.success && get_bool(gate.output, "clean") {
        stable = true;
        log("Gate clean after round " + round.to_string());
    } else {
        let errs = "";
        if gate != () && gate.success { errs = get_str(gate.output, "errors"); }
        if errs == "" { errs = "(gate agent returned no error detail - discover the failures yourself)"; }
        let fix_prompt = "";
        fix_prompt += "You are a stabilization fixer for the Cymphony Elixir repo. The build gate failed. Fix the failures below with minimal, narrowly scoped changes, ";
        fix_prompt += "then re-run the failing commands yourself to confirm they pass. " + CONVENTIONS + "\n\n";
        fix_prompt += "SHARED CONTRACT (keep interfaces consistent with it):\n" + contract + "\n\n";
        fix_prompt += "GATE FAILURES:\n" + errs;
        let fix = agent(fix_prompt, #{ label: "fix-" + round.to_string(), capability_mode: "execute" });
        if fix == () || !fix.success { log("Fixer round " + round.to_string() + " did not complete"); }
    }
}
if !stable { log("WARNING: stabilize loop exhausted " + MAX_STABILIZE_ROUNDS.to_string() + " rounds without a clean gate"); }

// ---------- Phase 6: Verify ----------

phase("Verify");
log("Running 6 parallel verifiers");

let verify_jobs = [];
let verify_names = ["antigravity-support", "codex-regression", "dashboard-controls", "harness-streaming", "static-gate", "make-all"];

let v1 = "";
v1 += "Verify the new Antigravity agent support in the Cymphony Elixir repo end to end. Use read_file/grep to inspect the code and run targeted tests with mix test on the relevant test files. ";
v1 += "Check: an adapter module under lib/cymphony_elixir/agent/ implements the CymphonyElixir.Agent behaviour the way agent/codex.ex does; config schema accepts agent.kind=antigravity plus a config.antigravity.* section; ";
v1 += "cli.ex expands 'agent antigravity'; run_spec_resolver handles agent:antigravity labels/directives; shell_provider captures env vars for the antigravity prefixes; tests exist and pass. ";
v1 += "passed=true ONLY with concrete evidence from files you read and test commands you ran. List every gap in problems.";
verify_jobs.push(#{ prompt: v1, label: "verify-antigravity", capability_mode: "execute", output_schema: verify_schema });

let v2 = "";
v2 += "Regression-check the existing Claude and Codex agent paths in the Cymphony Elixir repo after a large multi-agent change. ";
v2 += "Use git diff and read_file to inspect what changed in lib/cymphony_elixir/agent/claude.ex, agent/codex.ex, agent/runner.ex, orchestrator.ex, and config paths; ";
v2 += "run the claude/codex-related tests with mix test. Flag any unintended behavior change, removed feature, or broken contract for the existing kinds. ";
v2 += "passed=true ONLY with concrete evidence; list problems precisely.";
verify_jobs.push(#{ prompt: v2, label: "verify-codex-regression", capability_mode: "execute", output_schema: verify_schema });

let v3 = "";
v3 += "Verify the dashboard harness/model/reasoning customization and monitoring upgrades in the Cymphony Elixir repo. ";
v3 += "Read lib/cymphony_elixir_web/live/dashboard_live.ex, layouts, and assets; run the LiveView/dashboard tests with mix test. ";
v3 += "Check: per-project and per-session controls exist for harness (claude/codex/antigravity), model (with suggestions), and reasoning effort; the corresponding handle_event handlers and API routes exist and are wired to orchestrator/config persistence; ";
v3 += "monitoring surfaces (metric tiles, session detail, sparklines/history) render from real assigns. passed=true ONLY with concrete evidence; list problems precisely.";
verify_jobs.push(#{ prompt: v3, label: "verify-dashboard", capability_mode: "execute", output_schema: verify_schema });

let v4 = "";
v4 += "Verify the harness output streaming feature in the Cymphony Elixir repo. Trace the data path with read_file/grep: ";
v4 += "agent port output in lib/cymphony_elixir/agent/runner.ex -> bounded per-session ring buffer -> ObservabilityPubSub -> LiveView tail pane in dashboard_live.ex. ";
v4 += "Run the related tests with mix test. Check: the buffer is bounded (backpressure-safe), the LiveView subscribes and renders the stream in the expanded session view, ";
v4 += "and the stream works for all three agent kinds at the interface level. passed=true ONLY with concrete evidence; list problems precisely.";
verify_jobs.push(#{ prompt: v4, label: "verify-streaming", capability_mode: "execute", output_schema: verify_schema });

let v5 = "";
v5 += "Run the static quality gates for the Cymphony Elixir repo: 'make fmt-check' and 'make lint' (specs.check + credo --strict). ";
v5 += "passed=true only if both exit 0. evidence = tail of each command output. problems = each failure with the key lines.";
verify_jobs.push(#{ prompt: v5, label: "verify-static", capability_mode: "execute", output_schema: verify_schema });

let v6 = "";
v6 += "Run the full quality gate for the Cymphony Elixir repo: 'make all' (setup, build, fmt-check, lint, coverage, dialyzer). It may take a long time - be patient and let each stage finish. ";
v6 += "passed=true only if the whole command exits 0. evidence = the final summary lines. problems = each failing stage with its key error lines.";
verify_jobs.push(#{ prompt: v6, label: "verify-make-all", capability_mode: "execute", output_schema: verify_schema });

let vresults = parallel(verify_jobs);

let failures = "";
let pass_count = 0;
let report = "# Cymphony next-level run report\n\n## Goal\n" + GOALS + "\n\n## Verification\n";
let vn = 0;
for r in vresults {
    let name = verify_names[vn];
    if r != () && r.success && get_bool(r.output, "passed") {
        pass_count += 1;
        report += "- " + name + ": PASS - " + get_str(r.output, "evidence") + "\n";
    } else {
        let probs = "";
        if r != () && r.success && type_of(r.output) == "map" {
            let pl = get_arr(r.output, "problems");
            for pp in pl { probs += "  * " + s(pp) + "\n"; }
            if probs == "" { probs = "  * marked failed without listed problems: " + get_str(r.output, "evidence") + "\n"; }
        } else {
            probs = "  * verifier agent did not complete (treated as unverified)\n";
        }
        failures += "### " + name + "\n" + probs;
        report += "- " + name + ": FAIL\n";
    }
    vn += 1;
}
log("Verification: " + pass_count.to_string() + "/" + verify_names.len().to_string() + " passed");

// ---------- Remediation (fail-closed) ----------

let all_ok = pass_count == verify_names.len();
if !all_ok {
    log("Verification failures found - running one remediation round");
    let rem_prompt = "";
    rem_prompt += "You are the remediation agent for the Cymphony Elixir repo after a large multi-agent upgrade. Independent verifiers found the failures below. ";
    rem_prompt += "Fix all of them with minimal, convention-following changes; run the relevant commands to confirm each fix. " + CONVENTIONS + "\n\n";
    rem_prompt += "SHARED CONTRACT:\n" + contract + "\n\n";
    rem_prompt += "VERIFIER FAILURES:\n" + failures;
    let rem = agent(rem_prompt, #{ label: "remediate", capability_mode: "execute" });
    if rem == () || !rem.success { log("Remediation agent did not complete"); }

    let recheck_prompt = "";
    recheck_prompt += "Re-verify the Cymphony Elixir repo after remediation. Re-run exactly the checks that failed: " + failures + "\n";
    recheck_prompt += "passed=true only if every previously failing check now passes; list any remaining problems.";
    let recheck = agent(recheck_prompt, #{ label: "recheck", capability_mode: "execute", output_schema: verify_schema });
    if recheck != () && recheck.success && get_bool(recheck.output, "passed") {
        all_ok = true;
        report += "\n## Remediation\nAll previously failing checks now pass: " + get_str(recheck.output, "evidence") + "\n";
    } else {
        let re = "";
        if recheck != () && recheck.success {
            re = get_str(recheck.output, "evidence");
            let rp = get_arr(recheck.output, "problems");
            for pp in rp { re += "\n  * " + s(pp); }
        } else { re = "recheck agent did not complete"; }
        report += "\n## Remediation\nStill failing after remediation:\n" + re + "\n";
    }
}

// ---------- Phase 7: Report ----------

phase("Report");

report += "\n## Pipeline stats\n";
report += "- Packages implemented: " + impl_ok.to_string() + "/" + packages.len().to_string() + "\n";
report += "- Stabilize gate clean: " + stable + "\n";
let b = budget();
if b != () && type_of(b) == "map" && b.contains("spent") && b.contains("total") {
    report += "- Agents used: " + b.spent.to_string() + " of " + b.total.to_string() + "\n";
}
if notes != "" { report += "\n## User notes applied\n" + notes + "\n"; }

let report_path = write_scratch_file("report.md", report);
let summary = "Cymphony next-level upgrade: " + packages.len().to_string() + " packages, " + pass_count.to_string() + "/" + verify_names.len().to_string() + " verifiers passed";
if all_ok { summary += " - ALL GREEN"; } else { summary += " - issues remain, see report"; }
log(summary);

complete(#{ summary: summary, passed: all_ok, report_path: report_path, report: report });
