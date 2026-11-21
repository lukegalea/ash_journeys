defmodule AshJourneys.Test.JourneySource do
  @moduledoc """
  Compiles journey modules from source in tests, so a test can declare a variant of a
  journey and find the line each declaration is on.
  """

  @doc "The source of a journeys module named `module` holding `journeys`."
  @spec module(module(), String.t(), keyword()) :: String.t()
  def module(module, journeys, opts \\ []) do
    surfaces = Keyword.get(opts, :surfaces, "AshJourneys.Test.Surfaces")

    """
    defmodule #{inspect(module)} do
      use AshJourneys.Journeys,
        surfaces: #{surfaces},
        personas: AshJourneys.Test.Personas,
        world: AshJourneys.Test.World

    #{journeys}
    end
    """
  end

  @doc """
  One journey `:sample`, with two personas (`:admin`, `:leaver`), the world binding
  `:leaver`, and `steps`. `header` replaces the default header lines.
  """
  @spec journey(String.t(), keyword()) :: String.t()
  def journey(steps, opts \\ []) do
    name = Keyword.get(opts, :name, "sample")

    header =
      Keyword.get(opts, :header, """
      version 1
      kind :how_to
      title "A sample"
      goal "It is done."
      outcome "It is done."
      locales [:en]
      persona :admin, :tenant_admin
      persona :leaver, :member
      world bind: [leaver: {:user, :leaver}]
      """)

    """
    journey :#{name} do
    #{header}
    #{steps}
    end
    """
  end

  @doc "A fresh module name under `prefix`."
  @spec fresh(module()) :: module()
  def fresh(prefix), do: Module.concat(prefix, "J#{System.unique_integer([:positive])}")

  @doc """
  Compiles `source`, returning the modules it defined. Source locations are recorded,
  as `mix compile` records them (`mix test` turns `debug_info` off for test code).
  """
  @spec compile(String.t()) :: [module()]
  def compile(source) do
    Code.put_compiler_option(:debug_info, true)
    source |> Code.compile_string("journey_fixture.exs") |> Enum.map(&elem(&1, 0))
  end

  @doc "The 1-based line of the first line of `source` containing `text`."
  @spec line_of(String.t(), String.t()) :: pos_integer()
  def line_of(source, text) do
    source
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, text))
    |> Kernel.+(1)
  end
end
