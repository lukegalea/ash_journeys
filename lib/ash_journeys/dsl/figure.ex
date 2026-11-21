defmodule AshJourneys.Dsl.Figure do
  @moduledoc """
  A figure captured at this point of the step: what it frames, what it highlights,
  and the regions it masks. Every mask carries a fixed-width box, because a masked
  value whose width varies still moves the layout around it.
  """

  defstruct [:name, :highlight, frame: :page, mask: [], __spark_metadata__: nil]

  @type frame :: :page | :dialog | {:table, String.t()} | {:row, atom()}
  @type mask :: {atom(), [width: String.t()]}

  @type t :: %__MODULE__{
          name: atom(),
          frame: frame(),
          highlight: {:row, atom()} | nil,
          mask: [mask() | atom()]
        }
end
