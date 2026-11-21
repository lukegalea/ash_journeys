defmodule AshJourneys.Manifest.Figure do
  @moduledoc """
  One figure a step captured (`AshJourneys.Manifest.Step`).

    * `name`: the figure's name in the declaration.
    * `file`: its file name, beside the manifest.
    * `file_sha256`: the SHA-256 of the file's bytes, exactly as shot. This is the
      evidence hash, and nothing ever compares it with a tolerance.
    * `raster_sha256`, `width`, `height`: the raster hash of its pixels
      (`AshJourneys.Raster.hash/1`) and their dimensions. `nil` when the runner
      could not compute it, which leaves the figure unmeasured.
    * `settled`: whether the page had settled (no pending update, fonts loaded)
      when it was captured.
    * `highlight`: the highlighted element's box in the figure's pixels,
      `%{x:, y:, width:, height:}`, or `nil` when the figure highlights nothing.
  """

  defstruct [
    :name,
    :file,
    :file_sha256,
    :raster_sha256,
    :width,
    :height,
    :highlight,
    settled: false
  ]

  @type bbox :: %{x: number(), y: number(), width: number(), height: number()}

  @type t :: %__MODULE__{
          name: String.t(),
          file: String.t(),
          file_sha256: String.t(),
          raster_sha256: String.t() | nil,
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          settled: boolean(),
          highlight: bbox() | nil
        }
end
