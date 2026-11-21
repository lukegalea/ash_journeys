defmodule AshJourneys.Dsl.World do
  @moduledoc """
  The seeded world a journey runs in: the host packs to seed, the records the steps
  name, and the instant displayed timestamps are pinned to.
  """

  defstruct [:clock, packs: [], bind: [], timestamps: [], __spark_metadata__: nil]

  @type offset :: {integer(), :second | :minute | :hour | :day}

  @type t :: %__MODULE__{
          clock: DateTime.t() | nil,
          packs: [atom()],
          bind: [{atom(), {atom(), atom() | String.t()}}],
          timestamps: [{atom(), [{atom(), offset()}]}]
        }
end
