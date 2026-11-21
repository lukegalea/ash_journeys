defmodule Mix.Tasks.AshJourneys.Lock do
  @shortdoc "Reports, or checks, whether every journey's approved run proves its declaration"
  @moduledoc """
  `mix ash_journeys.lock [--check]`

  Compares each journey declared by the modules in
  `config :ash_journeys, journeys: [...]` with the run that
  `priv/journeys/journeys.lock.json` names for it, in each locale it declares, and
  prints one line each:

    * `current`: the approved run proves this declaration;
    * `stale`: the declaration changed after its run was approved;
    * `unapproved`: no run has been approved yet;
    * `orphaned`: the lock names a run for a journey or locale no longer declared.

  With `--check` it exits non-zero when any journey is stale, and for nothing else:
  a documentation page is wrong only when its declaration is newer than its proof.
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

    status = Lock.check(lock, declared)
    Mix.shell().info(format(status, map_size(declared)))

    if check? and status.stale != [] do
      Mix.raise(
        "ash_journeys.lock: #{length(status.stale)} journey(s) changed after their run was approved; " <>
          "run them and mix ash_journeys.approve <run-id>"
      )
    end
  end

  @doc false
  def format(status, declared) do
    lines =
      Enum.map(status.current, fn {id, locale} -> "current     #{id} #{locale}" end) ++
        Enum.map(status.stale, fn {id, locale, approved, now} ->
          "stale       #{id} #{locale}: approved #{short(approved)}, declared #{short(now)}"
        end) ++
        Enum.map(status.unapproved, fn {id, locale} -> "unapproved  #{id} #{locale}" end) ++
        Enum.map(status.orphaned, fn {id, locale} -> "orphaned    #{id} #{locale}" end)

    Enum.join(["ash_journeys.lock: #{declared} journey(s) declared" | lines], "\n")
  end

  defp short(hash), do: binary_part(hash, 0, 12)
end
