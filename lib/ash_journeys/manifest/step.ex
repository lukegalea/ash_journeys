defmodule AshJourneys.Manifest.Step do
  @moduledoc """
  What a run recorded for one step of a journey (`AshJourneys.Manifest`).

    * `name` and `actor`: the step and the persona it ran as, both from the
      declaration, not inferred from the spans.
    * `label`: how the runner labelled the step in its output, if it did.
    * `status`: `:passed`, `:failed`, `:errored` (the step could not be run to a
      verdict) or `:skipped` (an earlier step stopped the run).
    * `attempts`: how many times the step ran. Only a first attempt is a pass for
      approval or evidence.
    * `cursor`: the span window the step's assertions read, `%{from: n, to: m}` as
      positions in the run's span stream, `[from, to)`.
    * `correlation_id` and `span_ids`: the trace the step's actions produced.
    * `figures`: what the step captured (`AshJourneys.Manifest.Figure`).
    * `error`: the failure, for a step that did not pass.
  """

  defstruct [
    :name,
    :actor,
    :label,
    :status,
    :cursor,
    :correlation_id,
    :error,
    attempts: 1,
    span_ids: [],
    figures: []
  ]

  @type status :: :passed | :failed | :errored | :skipped

  @type t :: %__MODULE__{
          name: String.t(),
          actor: String.t(),
          label: String.t() | nil,
          status: status(),
          attempts: pos_integer(),
          cursor: %{from: non_neg_integer(), to: non_neg_integer()} | nil,
          correlation_id: String.t() | nil,
          span_ids: [String.t()],
          figures: [AshJourneys.Manifest.Figure.t()],
          error: String.t() | nil
        }

  @doc "The step statuses a manifest may record."
  @spec statuses() :: [status()]
  def statuses, do: [:passed, :failed, :errored, :skipped]
end
