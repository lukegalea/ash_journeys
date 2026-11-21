defmodule AshJourneys.Dsl.Open do
  @moduledoc "Opens a surface, by its id in the host's surface registry."

  defstruct [:surface, __spark_metadata__: nil]

  @type t :: %__MODULE__{surface: atom()}
end
