defmodule Mix.Tasks.AshJourneys.Gettext.Extract do
  @shortdoc "Extracts journeys' titles and narration into a .pot file"
  @moduledoc """
  `mix ash_journeys.gettext.extract [--output FILE] [--check-up-to-date | --check-translated]`

  Writes every msgid the journeys declared by the modules in
  `config :ash_journeys, journeys: [...]` say (titles, goals, outcomes, `say` and
  `note` text) to `priv/gettext/journeys.pot`, each with the file that declares it.
  The file's basename is its gettext domain, which must be `journeys`.

    * `--output`: the `.pot` path. Defaults to `priv/gettext/journeys.pot`.
    * `--check-up-to-date`: write nothing, and fail when the file differs from what
      extraction would write. Put it in the static checks.
    * `--check-translated`: write nothing, and fail when a journey's locale other than
      Gettext's default locale (the one the msgids are written in) has no translation
      for a msgid the journey says. Without it, a narration line nobody translated is
      published in the msgid's language, silently. Put it in the static checks.

  Then `mix gettext.merge priv/gettext --locale fr` and translate the `msgstr`s of
  `fr/LC_MESSAGES/journeys.po`.
  """

  use Mix.Task

  alias AshJourneys.L10n

  @default_output "priv/gettext/journeys.pot"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [output: :string, check_up_to_date: :boolean, check_translated: :boolean]
      )

    if rest != [] or invalid != [] or (opts[:check_up_to_date] && opts[:check_translated]),
      do:
        Mix.raise(
          "usage: mix ash_journeys.gettext.extract [--output FILE] " <>
            "[--check-up-to-date | --check-translated]"
        )

    output = Keyword.get(opts, :output, @default_output)

    if Path.basename(output, ".pot") != L10n.domain(),
      do: Mix.raise("the file must be named #{L10n.domain()}.pot: its name is its gettext domain")

    declared = Mix.AshJourneys.declared!()
    messages = L10n.messages(declared)
    content = L10n.pot(messages)

    cond do
      opts[:check_translated] ->
        check_translated!(declared)

      opts[:check_up_to_date] ->
        if File.read(output) != {:ok, content},
          do:
            Mix.raise(
              "#{output} is out of date. Run `mix ash_journeys.gettext.extract` and commit it."
            )

        Mix.shell().info("#{output} is up to date.")

      true ->
        output |> Path.dirname() |> File.mkdir_p!()
        File.write!(output, content)
        Mix.shell().info("#{output}: #{map_size(messages)} message(s) written.")
    end
  end

  defp check_translated!(declared) do
    source = to_string(Application.get_env(:gettext, :default_locale, "en"))

    case L10n.untranslated(declared, source) do
      [] ->
        Mix.shell().info("Every journey text has a translation in every declared locale.")

      missing ->
        Mix.AshJourneys.refuse!(
          "journey text with no translation (the msgids are written in #{source}):",
          for({id, locale, msgid} <- missing, do: "#{id}/#{locale}: #{inspect(msgid)}")
        )
    end
  end
end
