defmodule AshJourneys.Dsl.Step do
  @moduledoc """
  One step of a journey, taken by one persona. `body` holds what the step does and
  checks, in order (`open`, `row_action`, `figure`, `expect`); `narration` holds what
  the documentation says about it (`say`, `note`).
  """

  defstruct [:name, :as, body: [], narration: [], __spark_metadata__: nil]

  @type body ::
          AshJourneys.Dsl.Open.t()
          | AshJourneys.Dsl.RowAction.t()
          | AshJourneys.Dsl.Figure.t()
          | AshJourneys.Dsl.Expect.t()

  @type t :: %__MODULE__{
          name: atom(),
          as: atom(),
          body: [body()],
          narration: [AshJourneys.Dsl.Say.t() | AshJourneys.Dsl.Note.t()]
        }

  @doc false
  # `step :name, as: :persona do … end` arrives with `as: [as: :persona]`.
  def transform(%__MODULE__{as: [as: persona]} = step), do: {:ok, %{step | as: persona}}
  def transform(step), do: {:ok, step}
end
