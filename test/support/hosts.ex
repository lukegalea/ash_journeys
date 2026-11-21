defmodule AshJourneys.Test.Surfaces do
  @moduledoc false
  @behaviour AshJourneys.SurfaceRegistry

  @impl true
  # `:people_ui` moves the surface away from what a declaration was verified
  # against, as a rename after approval would.
  def surface(:people),
    do: %{ui: Application.get_env(:ash_journeys, :people_ui, AshJourneys.Test.Member)}

  def surface(:home), do: %{ui: nil}
  def surface(:sign_in), do: %{ui: nil}
  def surface(_id), do: nil
end

defmodule AshJourneys.Test.Personas do
  @moduledoc false
  @behaviour AshJourneys.Persona

  @impl true
  def actor(_role, name, bindings), do: Map.fetch(bindings, name)
end

defmodule AshJourneys.Test.World do
  @moduledoc false
  @behaviour AshJourneys.World

  @impl true
  def seed(_world, _opts), do: {:ok, %{}}

  @impl true
  def pin_timestamps(_bindings, _clock, _pins), do: :ok
end
