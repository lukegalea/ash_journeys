defmodule Mix.AshJourneys do
  @moduledoc false
  # What the ash_journeys tasks share: the configured journeys and how reports read.

  alias AshJourneys.{Approval, Lock}

  @doc "Compiles and reads `config :ash_journeys, journeys: [...]`. Starts nothing."
  @spec declared!() :: Lock.declared()
  def declared! do
    Mix.Task.run("compile")
    Mix.Task.run("app.config")

    case Lock.declared() do
      {:ok, declared} -> declared
      {:error, problems} -> Mix.raise(Enum.join(problems, "\n"))
    end
  end

  @doc "Raises with every problem, one per line, under `heading`."
  @spec refuse!(String.t(), [String.t()]) :: no_return()
  def refuse!(heading, problems),
    do: Mix.raise(Enum.join([heading | Enum.map(problems, &("  " <> &1))], "\n"))

  @doc "One line per figure comparison."
  @spec figure_lines([{String.t(), Approval.comparison()}]) :: [String.t()]
  def figure_lines(figures),
    do: Enum.map(figures, fn {key, comparison} -> "    #{key}: #{comparison(comparison)}" end)

  defp comparison(:unchanged), do: "unchanged"
  defp comparison(:added), do: "added"
  defp comparison(:removed), do: "removed"
  defp comparison({:within_tolerance, diff}), do: "within tolerance (#{pixels(diff)})"

  defp comparison({:changed, %{size: {{w1, h1}, {w2, h2}}}}),
    do: "changed (#{w1}x#{h1} -> #{w2}x#{h2})"

  defp comparison({:changed, %{} = diff}), do: "changed (#{pixels(diff)})"
  defp comparison({:changed, reason}), do: "changed (#{reason})"

  defp pixels(%{pixels: pixels, max_delta: delta, bbox: box}) do
    where = if box, do: " in #{box.width}x#{box.height} at #{box.x},#{box.y}", else: ""
    "#{pixels} px, channel delta up to #{delta}#{where}"
  end
end
