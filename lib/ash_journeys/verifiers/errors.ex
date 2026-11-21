defmodule AshJourneys.Verifiers.Errors do
  @moduledoc false

  alias Spark.Dsl.Verifier

  @doc "A located `Spark.Error.DslError` about `entity`, at `path` under the journeys section."
  @spec error(map(), struct() | nil, [atom() | String.t()], String.t()) ::
          Spark.Error.DslError.t()
  def error(dsl_state, entity, path, message) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl_state, :module),
      path: [:journeys | path],
      message: message,
      location: entity && Spark.Dsl.Entity.anno(entity)
    )
  end

  @doc "`:ok` for no errors, else `{:error, errors}`."
  @spec result([Spark.Error.DslError.t()]) :: :ok | {:error, [Spark.Error.DslError.t()]}
  def result([]), do: :ok
  def result(errors), do: {:error, errors}
end
