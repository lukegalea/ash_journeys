defmodule AshJourneys.Preflight do
  @moduledoc """
  The start-of-run check: what a journey's declaration claims that only the
  surfaces as a run will render them can confirm. A runner calls `check/3` before
  the first step and does not start a journey that fails it.

  Whether a row action asks for confirmation depends on how its surface renders
  (`AshA2ui.Manifest`'s `confirm` is `:destructive` only on the admin catalog), so
  it is checked here with the options the run renders with, not at compile time:

    * a row action declared `confirm: true` must ask for confirmation, and one that
      asks must be declared `confirm: true`;
    * a figure with `frame: :dialog` must follow a row action that asks for
      confirmation in the same step.
  """

  alias AshJourneys.Dsl.{Figure, RowAction, Step}
  alias AshJourneys.{Info, Ir, SurfaceLookup}

  @doc """
  Checks journey `name` of `module` against its surfaces' manifests, built with
  `manifest_opts` (`:catalog`, `:locale`, …, as the run renders them).
  """
  @spec check(module(), atom(), keyword()) :: :ok | {:error, [String.t()]}
  def check(module, name, manifest_opts \\ []) do
    registry = Info.surface_registry(module)

    module
    |> Info.journey!(name)
    |> Ir.step_surfaces()
    |> Enum.flat_map(&step(registry, manifest_opts, &1))
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp step(registry, opts, {%Step{name: name, body: body}, surface}) do
    {errors, _asked} =
      Enum.flat_map_reduce(body, nil, fn
        %RowAction{} = action, _asked ->
          case lookup(registry, surface, action.id, opts) do
            {:ok, %{confirm: confirm}} -> {confirm(name, action, confirm), confirm}
            {:error, message} -> {["step #{inspect(name)}: #{message}"], nil}
          end

        %Figure{frame: :dialog, name: figure}, nil ->
          {[
             """
             step #{inspect(name)}: figure #{inspect(figure)} frames a dialog, but no row action \
             before it asks for confirmation on this surface\
             """
           ], nil}

        _entity, asked ->
          {[], asked}
      end)

    errors
  end

  defp lookup(registry, surface, id, opts) do
    with {:ok, manifest} <- SurfaceLookup.manifest(registry, surface, opts) do
      SurfaceLookup.row_action(manifest, id, surface)
    end
  end

  defp confirm(_step, %RowAction{confirm: true}, confirm) when confirm != nil, do: []
  defp confirm(_step, %RowAction{confirm: false}, nil), do: []

  defp confirm(step, %RowAction{confirm: true, id: id}, nil) do
    [
      "step #{inspect(step)}: row action #{inspect(id)} is declared confirm: true, but asks for no confirmation"
    ]
  end

  defp confirm(step, %RowAction{confirm: false, id: id}, confirm) do
    [
      "step #{inspect(step)}: row action #{inspect(id)} asks for confirmation (#{confirm}); declare it confirm: true"
    ]
  end
end
