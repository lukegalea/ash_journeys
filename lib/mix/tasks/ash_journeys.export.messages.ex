defmodule Mix.Tasks.AshJourneys.Export.Messages do
  @shortdoc "Writes a run as a Cucumber Messages NDJSON stream"
  @moduledoc """
  `mix ash_journeys.export.messages RUN_DIR [--out FILE] [--embed]`

  Writes the run in `RUN_DIR` (`tmp/journeys/runs/<run-id>`) as one Cucumber Messages
  NDJSON stream (`AshJourneys.Messages`), to standard output or `--out`. It is a
  projection of the run's manifests: a step is `PASSED` only when it passed on its
  first attempt and everything it recorded was measured.

  A run directory that does not exist, holds no journeys, or holds a missing,
  malformed or misfiled manifest exports nothing and stops the task with every
  reason.

    * `--out`: the file to write, instead of standard output.
    * `--embed`: carry figures as base64 attachments instead of referencing their files.
  """

  use Mix.Task

  alias AshJourneys.Messages

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [out: :string, embed: :boolean])

    if length(rest) != 1 or invalid != [],
      do: Mix.raise("usage: mix ash_journeys.export.messages RUN_DIR [--out FILE] [--embed]")

    case Messages.candidates(hd(rest)) do
      {:ok, candidates} ->
        ndjson = candidates |> Messages.build(embed: opts[:embed] == true) |> Messages.encode()

        case opts[:out] do
          nil -> Mix.shell().info(String.trim_trailing(ndjson))
          out -> File.write!(out, ndjson)
        end

      {:error, problems} ->
        Mix.AshJourneys.refuse!("ash_journeys.export.messages: nothing was exported", problems)
    end
  end
end
