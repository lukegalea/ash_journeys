defmodule AshJourneys.Persona do
  @moduledoc """
  The host's personas: who a journey's `persona :name, :role` signs in as.

  A runner (`ash_browser_tests`) calls it once per persona, after the world is
  seeded, and signs a browser context in as the actor it returns. This package only
  declares the contract.
  """

  @doc """
  The actor persona `name` with host role `role` signs in as, in a seeded world.
  `bindings` are the world's bound records, by binding name (`AshJourneys.World`).
  """
  @callback actor(role :: atom(), name :: atom(), bindings :: %{atom() => term()}) ::
              {:ok, actor :: term()} | {:error, term()}
end
