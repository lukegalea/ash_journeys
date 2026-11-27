defmodule AshJourneys.L10n do
  @moduledoc """
  What a journey says, in the host's gettext backend.

  Titles, goals, outcomes, `say` and `note` text are msgids in the `journeys`
  domain, written in the language the journey is authored in. `mix
  ash_journeys.gettext.extract` collects them into `priv/gettext/journeys.pot`
  (`messages/1`, `pot/1`), and the host translates that file with ordinary Gettext
  tooling.

  `text/4` translates a msgid for a locale and fills its `%{name}` placeholders.
  `label/4` resolves a `ui/1` reference to the label its surface renders in that
  locale, through `AshA2ui.Manifest.for_surface/2` with the host backend's
  `ash_a2ui` and `a2ui_metadata` domains, so a renamed or translated button reaches
  every page without touching a journey.

  `texts/3` is all of a journey's text in one locale, resolved. A run records it
  (`AshJourneys.Manifest`), and a projection shows the text only while it still
  resolves the same (`AshJourneys.Lock.verify/6`): a renamed button or a changed
  translation needs a new run before any page says it, since the approved figures
  show what the run saw.
  """

  alias AshJourneys.{Info, SurfaceLookup}

  @domain "journeys"

  @doc "The gettext domain journeys' text lives in."
  @spec domain() :: String.t()
  def domain, do: @domain

  @doc """
  Every msgid the `declared` journeys (`AshJourneys.Lock.declared/1`) say, with the
  source files of the modules that declare them.
  """
  @spec messages(AshJourneys.Lock.declared()) :: %{String.t() => [String.t()]}
  def messages(declared) do
    declared
    |> Enum.flat_map(fn {_id, %{module: module, ir: ir}} ->
      file = source(module)
      for msgid <- msgids(ir), do: {msgid, file}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {msgid, files} -> {msgid, files |> Enum.uniq() |> Enum.sort()} end)
  end

  defp msgids(ir) do
    narration = for step <- ir["steps"], item <- step["narration"], do: item["text"]
    Enum.reject([ir["title"], ir["goal"], ir["outcome"] | narration], &is_nil/1)
  end

  defp source(module) do
    module.module_info(:compile)
    |> Keyword.fetch!(:source)
    |> to_string()
    |> Path.relative_to_cwd()
  end

  @doc """
  The msgids a declared locale has no translation for, as `{journey id, locale,
  msgid}`: every locale a journey declares except `source`, the locale the msgids
  are written in, and every msgid the journey says (`messages/1`) that the
  journey's Gettext backend answers by falling back to the msgid itself. An empty
  `msgstr` is no translation. Journeys with no backend have nothing to translate.
  """
  @spec untranslated(AshJourneys.Lock.declared(), String.t()) ::
          [{String.t(), String.t(), String.t()}]
  def untranslated(declared, source) do
    for {id, %{module: module, ir: ir}} <- Enum.sort(declared),
        backend = Info.gettext(module),
        backend != nil,
        locale <- ir["locales"],
        locale != source,
        msgid <- ir |> msgids() |> Enum.uniq(),
        not translated?(backend, locale, msgid),
        do: {id, locale, msgid}
  end

  defp translated?(backend, locale, msgid) do
    bindings =
      for [_, name] <- Regex.scan(~r/%\{(\w+)\}/, msgid), into: %{} do
        {String.to_existing_atom(name), ""}
      end

    match?({:ok, _}, backend.lgettext(locale, @domain, nil, msgid, bindings))
  end

  @doc "The `.pot` content for `messages/1`, entries sorted by msgid."
  @spec pot(%{String.t() => [String.t()]}) :: String.t()
  def pot(messages) do
    entries =
      messages
      |> Enum.sort()
      |> Enum.map_join("\n", fn {msgid, files} ->
        Enum.map_join(files, &"#: #{&1}\n") <> "msgid #{quote_po(msgid)}\nmsgstr \"\"\n"
      end)

    """
    ## This file is a PO Template file.
    ##
    ## `msgid`s here are the titles and narration of this application's journeys.
    ##
    ## Run `mix ash_journeys.gettext.extract` to refresh this file.
    ## Run `mix gettext.merge priv/gettext --locale LOCALE` to merge into a .po file.
    msgid ""
    msgstr ""
    "Content-Type: text/plain; charset=UTF-8\\n"
    "Content-Transfer-Encoding: 8bit\\n"
    "Domain: #{@domain}\\n"

    """ <> entries
  end

  defp quote_po(string) do
    escaped =
      string
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end

  @doc """
  `msgid` translated into `locale` by the Gettext `backend`, with `bindings` filled
  in. With no backend, the msgid as written. A placeholder left unbound, in the
  msgid or because a translation names one the journey does not bind, is an error.
  """
  @spec text(module() | nil, String.t(), %{atom() => String.t()}, String.t()) ::
          {:ok, String.t()} | {:error, [String.t()]}
  def text(backend, msgid, bindings, locale) do
    text =
      case backend do
        nil ->
          case Gettext.Interpolation.Default.runtime_interpolate(msgid, bindings) do
            {:ok, text} -> text
            {:missing_bindings, text, _missing} -> text
          end

        backend ->
          Gettext.with_locale(backend, locale, fn ->
            Gettext.dgettext(backend, @domain, msgid, bindings)
          end)
      end

    case Regex.run(~r/%\{\w+\}/, text) do
      nil -> {:ok, text}
      [placeholder] -> {:error, ["#{inspect(msgid)} in #{locale}: #{placeholder} is not bound"]}
    end
  end

  @doc """
  The label a `ui/1` binding of a journey's IR renders in `locale`: a surface's
  title, or a row action's button text. `registry` is the host's
  `AshJourneys.SurfaceRegistry`, `backend` its Gettext backend (or `nil`), and
  `manifest_opts` the `AshA2ui.Manifest` options the runs used (`:catalog`).
  Anything the surface no longer has is an error.
  """
  @spec label(map(), module(), module() | nil, String.t(), keyword()) ::
          {:ok, String.t()} | {:error, [String.t()]}
  def label(binding, registry, backend, locale, manifest_opts \\ []) do
    opts = Keyword.merge(manifest_opts, [locale: locale] ++ backend_opts(backend))

    with {:ok, surface} <- surface_id(binding["surface"]),
         {:ok, manifest} <- SurfaceLookup.manifest(registry, surface, opts),
         {:ok, label} <- resolve(binding, manifest, surface) do
      {:ok, label}
    else
      {:error, problem} -> {:error, [problem]}
    end
  end

  defp resolve(%{"type" => "surface"}, manifest, _surface), do: {:ok, manifest.title}

  defp resolve(%{"type" => "row_action", "id" => id}, manifest, surface) do
    with {:ok, action} <- SurfaceLookup.row_action(manifest, id, surface), do: {:ok, action.label}
  end

  defp backend_opts(nil), do: []
  defp backend_opts(backend), do: [gettext_backend: {backend, "ash_a2ui"}]

  defp surface_id(surface) when is_binary(surface) do
    {:ok, String.to_existing_atom(surface)}
  rescue
    ArgumentError -> {:error, "#{inspect(surface)} is not a surface"}
  end

  @doc """
  Every text of journey `journey` (`%{module:, ir:}`, as in
  `AshJourneys.Lock.declared/1`) in `locale`, resolved: `"title"`, `"goal"` and
  `"outcome"`; `"<step>.narration.<n>"` for each `say` and `note` (counted from
  1, a `say` with its `ui/1` labels filled in as plain text); and
  `"<step>.ui.<name>"` for each `ui/1` label. `manifest_opts` are the
  `AshA2ui.Manifest` options the surfaces render with (`label/5`). Every
  reference that does not resolve is an error.
  """
  @spec texts(%{module: module(), ir: map()}, String.t(), keyword()) ::
          {:ok, %{String.t() => String.t()}} | {:error, [String.t()]}
  def texts(%{module: module, ir: ir}, locale, manifest_opts \\ []) do
    backend = Info.gettext(module)
    registry = Info.surface_registry(module)

    header =
      for key <- ~w(title goal outcome),
          ir[key] != nil,
          do: {key, fn -> text(backend, ir[key], %{}, locale) end}

    steps =
      for step <- ir["steps"],
          {item, n} <- Enum.with_index(step["narration"], 1),
          entry <- narration(step["name"], item, n, registry, backend, locale, manifest_opts),
          do: entry

    {pairs, problems} =
      Enum.map_reduce(header ++ steps, [], fn {key, resolve}, problems ->
        case resolve.() do
          {:ok, text} -> {{key, text}, problems}
          {:error, more} -> {nil, problems ++ more}
        end
      end)

    if problems == [], do: {:ok, Map.new(pairs)}, else: {:error, Enum.uniq(problems)}
  end

  defp narration(
         step,
         %{"type" => "say", "text" => msgid, "bindings" => bindings},
         n,
         registry,
         backend,
         locale,
         opts
       ) do
    resolve = fn binding -> label(binding, registry, backend, locale, opts) end
    names = bindings |> Map.keys() |> Enum.sort()

    labels = for name <- names, do: {"#{step}.ui.#{name}", fn -> resolve.(bindings[name]) end}

    say =
      {"#{step}.narration.#{n}",
       fn ->
         with {:ok, filled} <- resolve_all(names, &resolve.(bindings[&1])) do
           text(
             backend,
             msgid,
             Map.new(Enum.zip(Enum.map(names, &String.to_existing_atom/1), filled)),
             locale
           )
         end
       end}

    [say | labels]
  end

  defp narration(step, %{"text" => msgid}, n, _registry, backend, locale, _opts),
    do: [{"#{step}.narration.#{n}", fn -> text(backend, msgid, %{}, locale) end}]

  defp resolve_all(names, resolve) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case resolve.(name) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
