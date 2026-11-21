defmodule AshJourneys.Verifiers.VerifyReferences do
  @moduledoc """
  Checks every reference a journey makes to the application:

    * each surface it opens, lands on or names with `ui/1` is in the host's
      `AshJourneys.SurfaceRegistry`;
    * each row action it performs or names with `ui({:row_action, id})`, and each
      table it frames, is in the `AshA2ui.Manifest` of the surface the step's
      persona is on (`AshJourneys.Ir.step_surfaces/1`);
    * each `{:ash_action, name}` in a trace is an action of the resource the step's
      row action runs on, or else of the surface's resource.

  It runs after the module compiles, so reading the registry and building manifests
  adds no compile-time dependency.
  """

  use Spark.Dsl.Verifier

  alias AshJourneys.Dsl.{Expect, Figure, Open, RowAction, Say, Step}
  alias AshJourneys.{Info, Ir, SurfaceLookup, Ui}
  alias AshJourneys.Verifiers.Errors

  @impl true
  def verify(dsl_state) do
    registry = Spark.Dsl.Verifier.get_persisted(dsl_state, :surfaces)

    # An unusable registry is VerifyHosts' error to report.
    if Code.ensure_loaded?(registry) and function_exported?(registry, :surface, 1) do
      dsl_state
      |> Info.journeys()
      |> Enum.flat_map(fn journey ->
        journey
        |> Ir.step_surfaces()
        |> Enum.flat_map(&step(dsl_state, registry, journey.name, &1))
      end)
      |> Errors.result()
    else
      :ok
    end
  end

  defp step(dsl, registry, journey, {%Step{} = step, surface}) do
    at = %{dsl: dsl, registry: registry, path: [journey, :step, step.name], surface: surface}
    resource = resource(at, step)

    Enum.flat_map(step.body, &body(at, &1, resource)) ++
      Enum.flat_map(step.narration, &narration(at, &1))
  end

  defp body(at, %Open{surface: surface} = open, _resource), do: surface(at, open, surface)

  defp body(at, %RowAction{id: id} = action, _resource) do
    case row_action(at, id) do
      {:ok, _action} -> []
      {:error, message} -> [err(at, action, "row action #{inspect(id)}: #{message}")]
    end
  end

  defp body(at, %Figure{frame: {:table, table}} = figure, _resource) do
    with {:ok, manifest} <- SurfaceLookup.manifest(at.registry, at.surface, []),
         ids = Enum.map(manifest.tables, & &1.id),
         false <- table in ids do
      [
        err(
          at,
          figure,
          "surface #{inspect(at.surface)} has no table #{inspect(table)} (it has #{inspect(ids)})"
        )
      ]
    else
      true ->
        []

      {:error, message} ->
        [
          err(
            at,
            figure,
            "figure #{inspect(figure.name)} frames table #{inspect(table)}: #{message}"
          )
        ]
    end
  end

  defp body(at, %Expect{} = expect, resource) do
    landed = if expect.lands_on, do: surface(at, expect, expect.lands_on), else: []

    actions =
      for {:ash_action, name} <- expect.trace,
          message = ash_action(resource, name),
          message != nil,
          do: err(at, expect, message)

    landed ++ actions
  end

  defp body(_at, _figure, _resource), do: []

  defp narration(at, %Say{bindings: bindings} = say) do
    Enum.flat_map(bindings, fn
      {_name, %Ui{target: {:row_action, id}}} ->
        case row_action(at, id) do
          {:ok, _action} -> []
          {:error, message} -> [err(at, say, "ui({:row_action, #{inspect(id)}}): #{message}")]
        end

      {_name, %Ui{target: surface}} ->
        surface(at, say, surface)

      _other ->
        []
    end)
  end

  defp narration(_at, _note), do: []

  defp surface(at, entity, id) do
    if SurfaceLookup.known?(at.registry, id),
      do: [],
      else: [err(at, entity, "#{inspect(id)} is not a surface in #{inspect(at.registry)}")]
  end

  defp row_action(at, id) do
    with {:ok, manifest} <- SurfaceLookup.manifest(at.registry, at.surface, []) do
      SurfaceLookup.row_action(manifest, id, at.surface)
    end
  end

  # The resource a step's traced Ash actions are checked against: its row action's,
  # or else its surface's.
  defp resource(at, %Step{body: body}) do
    case for(%RowAction{id: id} <- body, do: id) do
      [id | _] ->
        case row_action(at, id) do
          {:ok, action} -> action.resource
          {:error, _message} -> :unresolved
        end

      [] ->
        case SurfaceLookup.manifest(at.registry, at.surface, []) do
          {:ok, manifest} -> manifest.resource
          {:error, message} -> {:none, message}
        end
    end
  end

  # An unresolved row action is already reported against the row action itself.
  defp ash_action(:unresolved, _name), do: nil

  defp ash_action({:none, message}, name),
    do:
      "trace names Ash action #{inspect(name)}, but there is no resource to check it on: #{message}"

  defp ash_action(resource, name) do
    if Ash.Resource.Info.action(resource, name),
      do: nil,
      else: "trace names Ash action #{inspect(name)}, which #{inspect(resource)} does not have"
  end

  defp err(at, entity, message), do: Errors.error(at.dsl, entity, at.path, message)
end
