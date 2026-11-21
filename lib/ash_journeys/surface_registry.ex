defmodule AshJourneys.SurfaceRegistry do
  @moduledoc """
  The host's registry of surfaces, as journeys see it. Journey verification asks it
  whether each surface id a journey names exists, and which A2UI module renders it.

  A surface that is not an A2UI surface (a sign-in page, say) is still a surface a
  persona can open or land on; it returns `ui: nil`, and nothing on it can be named
  as a row action or a table.

  It is called when journey modules are verified, after compilation, so it may read
  the host's compiled registry freely.
  """

  @typedoc "What a journey needs to know about a surface."
  @type surface :: %{required(:ui) => module() | nil}

  @doc "The surface with `id`, or `nil` when the host has none."
  @callback surface(id :: atom()) :: surface() | nil
end
