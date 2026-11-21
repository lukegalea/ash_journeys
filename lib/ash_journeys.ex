defmodule AshJourneys do
  @moduledoc """
  Declarative user journeys for Ash applications.

  A journey is a typed, versioned claim about how one persona reaches one goal. Its
  steps name things the application already declares: surfaces, Ash actions, A2UI
  table and row-action ids. The compiled journey is the one source for:

    * a real-browser test that walks it (run by `ash_browser_tests`, test-only);
    * a sealed run manifest, which a host may record as evidence;
    * how-to and tutorial pages, per locale;
    * in-app help, and answers an agent can give.

  The governing rule: **a projection may show only what a passing run of the same
  journey version recorded.** Documentation is never written from a declaration
  that no run has proven.

  This package holds the declaration, its verification and the read projections.
  It has no browser dependency and is safe to ship in a release.

    * `AshJourneys.Journeys` declares journeys and `AshJourneys.Dsl` describes the
      DSL; its verifiers check every reference when the module compiles.
    * `AshJourneys.Info` reads a module's journeys, and `AshJourneys.Ir` turns one
      into JSON data with an RFC 8785 content hash.
    * `AshJourneys.Preflight` is the start-of-run check a runner makes first.
    * `AshJourneys.Manifest` is what a run records, and `AshJourneys.Run` where it
      writes it. `AshJourneys.Approval` publishes a passing run to
      `priv/journeys/`, `AshJourneys.Lock` records which run proves each journey,
      `AshJourneys.Impact` shows what approving a run would change, and
      `AshJourneys.Raster` compares figures by their pixels. The tasks are
      `mix ash_journeys.approve`, `mix ash_journeys.lock` and
      `mix ash_journeys.impact`.
    * `AshJourneys.SurfaceRegistry`, `AshJourneys.Persona`, `AshJourneys.World`,
      `AshJourneys.EvidenceSink` and `AshJourneys.FigureStore` are what a host
      implements.

  Early: the API will change. See `README.md`.
  """
end
