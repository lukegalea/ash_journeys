defmodule AshJourneys.Dsl.Expect do
  @moduledoc """
  What a step must have caused: a trace chain (optionally under one correlation id,
  with the audit rows it wrote), a record's attributes, or the surface a persona lands
  on.
  """

  defstruct [
    :record,
    :lands_on,
    trace: [],
    one_correlation: false,
    audit: false,
    __spark_metadata__: nil
  ]

  @type trace_entry :: atom() | {:ash_action, atom()}

  @type t :: %__MODULE__{
          trace: [trace_entry()],
          one_correlation: boolean(),
          audit: boolean(),
          record: {atom(), keyword()} | nil,
          lands_on: atom() | nil
        }
end
