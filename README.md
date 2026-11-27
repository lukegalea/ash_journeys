# AshJourneys

Declarative user journeys for Ash. Early: the API will change.

A journey is a typed, versioned claim about how one persona reaches one goal. Its
steps are written as references to things the application already declares, such
as surface ids, Ash actions and A2UI table and row-action ids. They are never
prose matched by regular expressions or CSS selectors. A rename then fails the
build instead of leaving the documentation out of date.

The compiled journey is the one source for several outputs:

| Output | Where it comes from |
|---|---|
| A real-browser test that walks the journey and asserts the trace of each step | `ash_browser_tests` (test-only) |
| A sealed run manifest: commit, steps, outcomes, figure hashes | this package, recorded by the host |
| How-to and tutorial pages, per locale | this package, from approved runs |
| In-app help and agent answers | this package, read by the host |
| A coverage ledger: every screen is documented, or waived with a reason | `ash_browser_tests` |

## The rule

**A projection may show only what a passing run of the same journey version
recorded.** A run writes candidate figures. `mix ash_journeys.approve` commits
them with their hashes to a lock file, and `mix ash_journeys.lock --check` fails
when a journey is newer than its approved run: its declaration, the browser build
the lock pins, or the text and labels it resolves to.

## A journey

```elixir
defmodule MyApp.Journeys.Offboarding do
  use AshJourneys.Journeys,
    surfaces: MyApp.Journeys.Surfaces,   # AshJourneys.SurfaceRegistry
    personas: MyApp.Journeys.Personas,   # AshJourneys.Persona
    world: MyApp.Journeys.World          # AshJourneys.World

  journey :revoke_a_leavers_access do
    version 1
    kind :how_to
    title "Revoke a leaver's access"
    goal "Their sign-in stops working."
    outcome "Their access is revoked."
    locales [:en, :fr]
    metadata controls: ["AC-2"]          # opaque: only the host reads it

    persona :admin, :tenant_admin
    persona :leaver, :member

    world packs: [:offboarding],
          bind: [leaver: {:user, :leaver}],
          clock: ~U[2026-03-02 09:00:00Z],
          timestamps: [leaver: [created_on: {30, :minute}]]

    step :find_the_person, as: :admin do
      open :users
      say "Open %{surface} and find the person who is leaving.", surface: ui(:users)

      figure :people,
        frame: {:table, "table"},
        highlight: {:row, :leaver},
        mask: [{:as_of, width: "6rem"}]
    end

    step :deactivate, as: :admin do
      row_action "table.deactivate", on: :leaver, confirm: true
      figure :confirm, frame: :dialog
      say "Choose %{action} and confirm.", action: ui({:row_action, "table.deactivate"})
      note :warning, "The next thing they do in the app sends them to sign in."
      expect trace: [:handle_event, {:ash_action, :deactivate}], one_correlation: true, audit: true
      expect record: {:leaver, lifecycle_status: :inactive}
    end
  end
end
```

The verifiers check, when the module compiles:

- every surface id against the host's surface registry;
- every row-action and table id against the `AshA2ui.Manifest` of the surface the
  step's persona is on (ash_a2ui is an optional dependency);
- every traced Ash action against the resource the row action runs on;
- that steps name declared personas and bound records, every step has narration,
  placeholders match their `ui/1` bindings, a `:dialog` frame follows a row action
  declared `confirm: true`, and every mask has a fixed-width box.

Errors carry the location of the declaration and fail
`mix compile --warnings-as-errors`. What only a rendered surface can confirm, such
as whether a row action really asks for confirmation on the catalog a run uses, is
checked by `AshJourneys.Preflight.check/3` before a run starts.

`AshJourneys.Info.ir/2` gives a journey as JSON data, and `AshJourneys.Info.hash/2`
the SHA-256 of its RFC 8785 canonical JSON. The same declaration gives the same
hash however it is spelled; any change gives a different one.

## Runs, approval and the lock

A runner (`ash_browser_tests`) walks a journey and writes a candidate for each
journey and locale under `tmp/journeys/runs/<run-id>/<journey>/<locale>/`: the
figures, and a run manifest (`AshJourneys.Manifest`). The manifest records the
commit, the journey's version and declaration hash, the locale, the environment
class (`:test`, `:staging` or `:operated`), the browser's name, version and
executable, the framing profile, the retries, and every text the journey's pages
show as the run resolved it in its locale (`AshJourneys.L10n.texts/3`): the
translated title, goal, outcome and narration, and each `ui/1` label. For each
step it records the
status, the persona it ran as, its attempts, its span cursor window, its
correlation id and span ids, and each figure's file hash, raster hash, settled
state and highlight box.

Name the modules that declare journeys:

```elixir
config :ash_journeys, journeys: [MyApp.Journeys.Offboarding]
```

`AshJourneys.Lock.declared/0` reads that list outside the tasks, for a host that
checks a reference to a journey (in a control file, say).

Then:

| Task | What it does |
|---|---|
| `mix ash_journeys.impact <run-id>` | Says whether the run is approvable, with every reason it is not, and how each figure compares with the approved one. Writes each changed figure beside its approved version, with the differing pixels marked, to `tmp/journeys/impact/<run-id>/`. |
| `mix ash_journeys.approve <run-id>` | Copies the run's manifests and figures, byte for byte, to `priv/journeys/<locale>/<journey>/` and records their hashes in `priv/journeys/journeys.lock.json`. |
| `mix ash_journeys.lock --check` | Fails when a journey's approved run no longer proves it (`AshJourneys.Lock.verify/6`): the declaration changed, the lock pins another build, an approved file or the lock entry is not what approval wrote, or a text or label resolves differently than the run recorded. An unapproved journey is reported and passes. Without `--check` it only reports. |

`approve` refuses the whole run, and writes nothing, when any part of it is not
approvable:

- a manifest is missing or does not read;
- the run failed or errored, or any step needed a retry: only a pass on the first
  attempt counts;
- a declared step was not recorded, did not pass, ran as another persona, or was
  not measured (no cursor window, or a trace expected and none recorded);
- a declared figure was not captured, was captured before the page settled, has no
  raster hash, or has a file whose bytes or pixels do not match its manifest;
- the run is of another declaration than the current one;
- a text it recorded is not what the journey resolves to now, so no page would
  name a label its figures do not show;
- the run is from a browser build other than the one the lock pins. The first
  approval pins the build it ran on; moving the pin is an edit to the lock.

Figures are compared by their raster: the decoded pixels as 8-bit RGBA, hashed with
their width and height (`AshJourneys.Raster`). A browser update can change a PNG's
bytes without changing its pixels. Within the lock's tolerance (at first at most 32
pixels, none off by more than 64 in any channel), a differing raster counts as
unchanged. The tolerance only decides whether a figure changed for review. Every hash
the lock and the manifests record is exact. When an approved run already proves the
same declaration on the same build, with every figure unchanged in that sense,
`approve` keeps it as it is, so re-shooting an unchanged journey changes no committed
file.

## Documentation pages and translation

Journeys' titles and narration are gettext msgids in a `journeys` domain, and the
labels `ui/1` interpolates come from the host backend's `a2ui_metadata` and
`ash_a2ui` domains (pass `gettext: MyAppWeb.Gettext` to `use AshJourneys.Journeys`).

| Task | What it does |
|---|---|
| `mix ash_journeys.gettext.extract` | Writes every msgid the journeys say to `priv/gettext/journeys.pot`. With `--check-up-to-date` it writes nothing and fails when the file differs from what extraction would write. |
| `mix ash_journeys.export` | Writes `docs/journeys/<locale>/<journey>.md` for each journey in each locale it declares, with its figures as `docs/journeys/figures/<digest>.png`. `--out`, and `--figures` with `--figures-ref`, say where. |

`export` reads only `priv/journeys/`: the lock and the approved runs, never a run in
progress. It refuses the whole export, writing nothing, when a journey is
unapproved, stale, altered since approval, or drifted: a label or translation
resolves differently than the approved run recorded, or no longer resolves. A
renamed button or a changed translation therefore needs a new run, approved,
before any page says it. Pages name each figure by the digest the lock records. A capture paints
masked regions magenta (`AshJourneys.Export.capture_mask_color/0`); published
figures show them in a neutral grey, and a figure with no masked pixel is the
approved file byte for byte.

## Cucumber Messages

`mix ash_journeys.export.messages tmp/journeys/runs/<run-id>` writes one run as a
[Cucumber Messages](https://github.com/cucumber/messages) NDJSON stream (to standard
output, or to `--out FILE`), so report tooling that reads that protocol can read it.
Figures are attachments by sha256 and media type, referenced by their `file:` URL
unless `--embed` carries the bytes. It is a projection of the run's manifests and
reads nothing else:

- a step is `PASSED` only when it passed on its first attempt and everything it
  recorded was measured; a retried, errored or unmeasured step is `UNKNOWN`, and says why;
- `testRunFinished.success` is true only when every manifest passed with no retry and
  every step is `PASSED`;
- a manifest records no clock, so timestamps are the epoch and durations zero;
- a missing, malformed or misfiled manifest exports nothing and fails the task.

Every message is validated in tests against the published JSON schema, vendored at
`test/fixtures/cucumber_messages/` with its version and licence (MIT).

## Prior art

The ideas come from Specification by Example and Living Documentation (Adzic,
Martraire), the Screenplay pattern (Serenity BDD), Concordion and Doc Detective.
This package applies them to an Ash application's own metadata.

## Install

The package is pinned by GitHub ref and is not on Hex:

```elixir
{:ash_journeys, github: "lukegalea/ash_journeys", ref: "<commit sha>"}
```

MIT licensed.
