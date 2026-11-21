defmodule AshJourneys.Dsl.Persona do
  @moduledoc "A persona in a journey: a name the steps use, and the host role it signs in as."

  defstruct [:name, :role, __spark_metadata__: nil]

  @type t :: %__MODULE__{name: atom(), role: atom()}
end
