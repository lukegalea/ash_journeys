defmodule AshJourneys.EvidenceSink do
  @moduledoc """
  Where the host records a journey run as evidence. A passing run (every step passed
  on its first attempt) may be recorded as evidence; a failing one as a finding. What
  counts, and against which controls, is the host's to decide: it reads the journey's
  opaque `metadata`, which this package never interprets. This package only declares
  the contract.
  """

  @doc """
  Records one run. `manifest` is the run manifest a runner wrote; `ir` is the
  journey's IR (`AshJourneys.Ir`), which carries the declaration hash and metadata.
  `opts` carries the run's context, as `c:AshJourneys.World.seed/2`'s does: the tenant
  it ran in, say, which the manifest does not record.
  """
  @callback record(manifest :: map(), ir :: AshJourneys.Ir.t(), opts :: keyword()) ::
              :ok | {:error, term()}
end
