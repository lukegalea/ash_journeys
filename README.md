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
when a declaration is newer than its approved run.

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
