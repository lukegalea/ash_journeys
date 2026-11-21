defmodule AshJourneys.SurfaceLookup do
  @moduledoc false
  # Surfaces and their A2UI manifests, for the verifiers and the start-of-run check.
  # ash_a2ui is optional: without it, nothing on a surface can be named.

  @compile {:no_warn_undefined, AshA2ui.Manifest}

  @doc "Whether the registry has a surface `id`."
  @spec known?(module(), atom()) :: boolean()
  def known?(registry, id), do: registry.surface(id) != nil

  @doc "The A2UI manifest of the registered surface `id`, built with `opts`."
  @spec manifest(module(), atom() | nil, keyword()) :: {:ok, map()} | {:error, String.t()}
  def manifest(_registry, nil, _opts),
    do: {:error, "its persona has no surface open; `open` one first"}

  def manifest(registry, id, opts) do
    case registry.surface(id) do
      nil ->
        {:error, "#{inspect(id)} is not a surface in #{inspect(registry)}"}

      %{ui: nil} ->
        {:error,
         "surface #{inspect(id)} is not an A2UI surface, so it has no tables or row actions"}

      %{ui: ui} ->
        if Code.ensure_loaded?(AshA2ui.Manifest),
          do: {:ok, AshA2ui.Manifest.for_surface(ui, opts)},
          else: {:error, "naming a table or row action needs ash_a2ui, which is not loaded"}
    end
  end

  @doc "The manifest's row action `id`, or an error naming the ones it has."
  @spec row_action(map(), String.t(), atom()) :: {:ok, map()} | {:error, String.t()}
  def row_action(manifest, id, surface) do
    case Enum.find(manifest.row_actions, &(&1.id == id)) do
      nil ->
        {:error,
         "surface #{inspect(surface)} has no row action #{inspect(id)} " <>
           "(it has #{inspect(Enum.map(manifest.row_actions, & &1.id))})"}

      action ->
        {:ok, action}
    end
  end
end
