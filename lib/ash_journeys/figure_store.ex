defmodule AshJourneys.FigureStore do
  @moduledoc """
  Where the host keeps the bytes of journey figures, addressed by their SHA-256. This
  package only declares the contract.
  """

  @doc """
  Stores a figure's bytes. `meta` names it (journey, version, step, figure, locale) and
  carries its hashes. Returns the reference the run manifest records.
  """
  @callback put(bytes :: binary(), meta :: map()) :: {:ok, ref :: String.t()} | {:error, term()}

  @doc "The bytes stored under `ref`."
  @callback fetch(ref :: String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
end
