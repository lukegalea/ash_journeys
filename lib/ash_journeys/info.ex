defmodule AshJourneys.Info do
  @moduledoc """
  Reads the journeys a module declares (`AshJourneys.Journeys`).

      AshJourneys.Info.journeys(MyApp.Journeys.Offboarding)
      AshJourneys.Info.ir(MyApp.Journeys.Offboarding, :revoke_a_leavers_access)
      AshJourneys.Info.hash(MyApp.Journeys.Offboarding, :revoke_a_leavers_access)
  """

  use Spark.InfoGenerator, extension: AshJourneys.Dsl, sections: [:journeys]

  alias AshJourneys.Dsl.Journey
  alias AshJourneys.Ir

  @doc "The journey named `name`, or `nil`."
  @spec journey(module(), atom()) :: Journey.t() | nil
  def journey(module, name), do: Enum.find(journeys(module), &(&1.name == name))

  @doc "The journey named `name`. Raises `ArgumentError` when the module declares none."
  @spec journey!(module(), atom()) :: Journey.t()
  def journey!(module, name) do
    journey(module, name) ||
      raise ArgumentError, "#{inspect(module)} declares no journey #{inspect(name)}"
  end

  @doc "The IR of the journey named `name` (`AshJourneys.Ir`)."
  @spec ir(module(), atom()) :: Ir.t()
  def ir(module, name), do: module |> journey!(name) |> Ir.build()

  @doc "The content hash of the journey named `name` (`AshJourneys.Ir.hash/1`)."
  @spec hash(module(), atom()) :: String.t()
  def hash(module, name), do: module |> ir(name) |> Ir.hash()

  @doc "The module's `AshJourneys.SurfaceRegistry` (its `surfaces:` option)."
  @spec surface_registry(module()) :: module()
  def surface_registry(module), do: Spark.Dsl.Extension.get_persisted(module, :surfaces)

  @doc "The module's `AshJourneys.Persona` (its `personas:` option)."
  @spec persona_module(module()) :: module()
  def persona_module(module), do: Spark.Dsl.Extension.get_persisted(module, :personas)

  @doc "The module's `AshJourneys.World` (its `world:` option)."
  @spec world_module(module()) :: module()
  def world_module(module), do: Spark.Dsl.Extension.get_persisted(module, :world)
end
