defmodule AshJourneys.World do
  @moduledoc """
  The host's seeded world: the data a journey runs against.

  A runner calls `seed/2` before the first step, then `pin_timestamps/3` so that
  every timestamp a figure displays is the same on every run. Pinning a seed's own
  timestamps, rather than faking the server's clock, keeps the data real: only the
  instant it was written is chosen. This package only declares the contract.
  """

  @doc """
  Seeds the world's `packs` and resolves its `bind` references (`{kind, key}`) to
  records, returned by binding name. `opts` carries the run's context (a tenant, say).
  """
  @callback seed(world :: AshJourneys.Dsl.World.t(), opts :: keyword()) ::
              {:ok, bindings :: %{atom() => term()}} | {:error, term()}

  @doc """
  Sets each bound record's listed attributes to `clock` plus its offset. `pins` is
  the world's `timestamps`, with offsets in seconds.
  """
  @callback pin_timestamps(
              bindings :: %{atom() => term()},
              clock :: DateTime.t(),
              pins :: %{atom() => %{atom() => integer()}}
            ) :: :ok | {:error, term()}
end
