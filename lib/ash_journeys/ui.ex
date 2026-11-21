defmodule AshJourneys.Ui do
  @moduledoc """
  A reference to a label the application renders, for narration to interpolate:

      say "Open %{surface} and choose %{action}.",
        surface: ui(:users),
        action: ui({:row_action, "people.deactivate"})

  `ui(surface_id)` is the surface's title and `ui({:row_action, id})` is the row
  action's button text, both resolved for the locale being rendered. A renamed
  button therefore renames itself in every locale's documentation, and an unknown
  reference fails verification.
  """

  defstruct [:target]

  @type target :: atom() | {:row_action, String.t()}
  @type t :: %__MODULE__{target: target()}

  @doc "A reference to the label of a surface (`id`) or a row action (`{:row_action, id}`)."
  @spec ui(target()) :: t()
  def ui(target) when is_atom(target), do: %__MODULE__{target: target}
  def ui({:row_action, id} = target) when is_binary(id), do: %__MODULE__{target: target}

  def ui(other) do
    raise ArgumentError,
          "ui/1 takes a surface id or {:row_action, id}, got: #{inspect(other)}"
  end
end
