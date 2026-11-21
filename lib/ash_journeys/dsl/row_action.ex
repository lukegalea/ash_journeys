defmodule AshJourneys.Dsl.RowAction do
  @moduledoc """
  Performs a row action, by its A2UI manifest id, on the row of a bound world record.
  `confirm: true` declares that the action asks for confirmation and the journey
  confirms it.
  """

  defstruct [:id, :on, confirm: false, __spark_metadata__: nil]

  @type t :: %__MODULE__{id: String.t(), on: atom(), confirm: boolean()}
end
