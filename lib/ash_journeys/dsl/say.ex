defmodule AshJourneys.Dsl.Say do
  @moduledoc """
  Narration: a gettext msgid, with `%{name}` placeholders bound to `ui/1` references.
  """

  defstruct [:text, bindings: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{text: String.t(), bindings: [{atom(), AshJourneys.Ui.t()}]}
end
