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
