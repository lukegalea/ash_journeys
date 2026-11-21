defmodule Mix.Tasks.AshJourneys.Gettext.Extract do
  @shortdoc "Extracts journeys' titles and narration into a .pot file"
  @moduledoc """
  `mix ash_journeys.gettext.extract [--output FILE] [--check-up-to-date]`

  Writes every msgid the journeys declared by the modules in
  `config :ash_journeys, journeys: [...]` say (titles, goals, outcomes, `say` and
  `note` text) to `priv/gettext/journeys.pot`, each with the file that declares it.
  The file's basename is its gettext domain, which must be `journeys`.

    * `--output`: the `.pot` path. Defaults to `priv/gettext/journeys.pot`.
    * `--check-up-to-date`: write nothing, and fail when the file differs from what
      extraction would write. Put it in the static checks.

  Then `mix gettext.merge priv/gettext --locale fr` and translate the `msgstr`s of
  `fr/LC_MESSAGES/journeys.po`.
  """

  use Mix.Task

  alias AshJourneys.L10n

  @default_output "priv/gettext/journeys.pot"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [output: :string, check_up_to_date: :boolean])

    if rest != [] or invalid != [],
      do:
        Mix.raise("usage: mix ash_journeys.gettext.extract [--output FILE] [--check-up-to-date]")

    output = Keyword.get(opts, :output, @default_output)

    if Path.basename(output, ".pot") != L10n.domain(),
      do: Mix.raise("the file must be named #{L10n.domain()}.pot: its name is its gettext domain")

    messages = Mix.AshJourneys.declared!() |> L10n.messages()
    content = L10n.pot(messages)

    if opts[:check_up_to_date] do
      if File.read(output) != {:ok, content},
        do:
          Mix.raise(
            "#{output} is out of date. Run `mix ash_journeys.gettext.extract` and commit it."
          )

      Mix.shell().info("#{output} is up to date.")
    else
      output |> Path.dirname() |> File.mkdir_p!()
      File.write!(output, content)
      Mix.shell().info("#{output}: #{map_size(messages)} message(s) written.")
    end
  end
end
