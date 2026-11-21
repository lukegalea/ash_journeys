defmodule AshJourneys.Verifiers.VerifyHosts do
  @moduledoc """
  Checks that the `surfaces:`, `personas:` and `world:` options of
  `use AshJourneys.Journeys` name modules implementing their behaviours.
  """

  use Spark.Dsl.Verifier

  alias AshJourneys.Verifiers.Errors

  @hosts [
    surfaces: AshJourneys.SurfaceRegistry,
    personas: AshJourneys.Persona,
    world: AshJourneys.World
  ]

  @impl true
  def verify(dsl_state) do
    @hosts
    |> Enum.flat_map(fn {option, behaviour} ->
      module = Spark.Dsl.Verifier.get_persisted(dsl_state, option)

      if Code.ensure_loaded?(module) and Spark.implements_behaviour?(module, behaviour) do
        []
      else
        [
          Errors.error(
            dsl_state,
            nil,
            [],
            "#{option}: #{inspect(module)} must be a module implementing #{inspect(behaviour)}"
          )
        ]
      end
    end)
    |> Errors.result()
  end
end
