defmodule AshJourneys.Dsl.Note do
  @moduledoc "An aside in the narration: a tip, some information, or a warning."

  defstruct [:kind, :text, __spark_metadata__: nil]

  @type t :: %__MODULE__{kind: :info | :tip | :warning, text: String.t()}
end
