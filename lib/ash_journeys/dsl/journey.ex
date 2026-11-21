defmodule AshJourneys.Dsl.Journey do
  @moduledoc "A declared journey: one persona reaching one goal, in ordered steps."

  defstruct [
    :name,
    :version,
    :kind,
    :title,
    :goal,
    :outcome,
    :world,
    locales: [],
    metadata: [],
    personas: [],
    steps: [],
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          version: pos_integer(),
          kind: :tutorial | :how_to,
          title: String.t(),
          goal: String.t(),
          outcome: String.t(),
          world: AshJourneys.Dsl.World.t() | nil,
          locales: [atom()],
          metadata: keyword(),
          personas: [AshJourneys.Dsl.Persona.t()],
          steps: [AshJourneys.Dsl.Step.t()]
        }
end
