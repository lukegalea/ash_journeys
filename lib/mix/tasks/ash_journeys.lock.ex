defmodule Mix.Tasks.AshJourneys.Lock do
  @shortdoc "Reports, or checks, whether every journey's approved run proves its declaration"
  @moduledoc """
  `mix ash_journeys.lock [--check]`

  Compares each journey declared by the modules in
  `config :ash_journeys, journeys: [...]` with the run that
  `priv/journeys/journeys.lock.json` names for it, in each locale it declares, and
  prints one line each:

    * `current`: the approved run proves this declaration;
    * `stale`: the declaration changed after its run was approved, or the run is
      from another browser build than the one the lock pins;
    * `altered`: an approved file, or the lock entry, is not what approval wrote;
    * `drifted`: the journey's text or a label no longer resolves to what the run
      recorded;
    * `unapproved`: no run has been approved yet;
    * `orphaned`: the lock names a run for a journey or locale no longer declared.

  With `--check` it exits non-zero when any journey is stale, altered or drifted
  (`AshJourneys.Lock.verify/6`): a documentation page is wrong when it is newer
  than its proof. An unapproved journey is reported and passes.
  A lock that does not read stops the task, since then nothing could be checked.

  The lock is written by `mix ash_journeys.approve`. This task never writes it.
  """

  use Mix.Task

  alias AshJourneys.Lock

  @impl true
  def run(args) do
    check? =
      case OptionParser.parse(args, strict: [check: :boolean]) do
        {opts, [], []} -> opts[:check] || false
        _ -> Mix.raise("usage: mix ash_journeys.lock [--check]")
      end

    declared = Mix.AshJourneys.declared!()

    lock =
      case Lock.read(File.cwd!()) do
        {:ok, lock} ->
          lock

        {:error, problems} ->
          Mix.AshJourneys.refuse!("ash_journeys.lock: the lock does not read", problems)
      end

    status = Lock.check(File.cwd!(), lock, declared)
    Mix.shell().info(format(status, map_size(declared)))
    failing = status.stale ++ status.altered ++ status.drifted

    if check? and failing != [] do
      Mix.raise(
        "ash_journeys.lock: #{length(failing)} journey(s) are not proven by their approved run; " <>
          "run them and mix ash_journeys.approve <run-id>"
      )
    end
  end

  @doc false
  def format(status, declared) do
    lines =
      Enum.map(status.current, fn {id, locale} -> "current     #{id} #{locale}" end) ++
        refused("stale", status.stale) ++
        refused("altered", status.altered) ++
        refused("drifted", status.drifted) ++
        Enum.map(status.unapproved, fn {id, locale} -> "unapproved  #{id} #{locale}" end) ++
        Enum.map(status.orphaned, fn {id, locale} -> "orphaned    #{id} #{locale}" end)

    Enum.join(["ash_journeys.lock: #{declared} journey(s) declared" | lines], "\n")
  end

  defp refused(kind, entries) do
    for {id, locale, reasons} <- entries,
        {reason, n} <- Enum.with_index(reasons) do
      if n == 0,
        do: String.pad_trailing(kind, 12) <> "#{id} #{locale}: #{reason}",
        else: String.duplicate(" ", 12) <> "  #{reason}"
    end
  end
end
