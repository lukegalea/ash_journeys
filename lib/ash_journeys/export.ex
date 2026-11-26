defmodule AshJourneys.Export do
  @moduledoc """
  The journeys as documentation pages: one Diataxis how-to or tutorial page per
  journey and locale, as Markdown, with its figures.

  A page is built from the approved IR and the lock, never from a run in progress:
  `pages/3` reads `priv/journeys/` (the lock, and the approved manifests and figures
  it names) and nothing under `tmp/`. It refuses the whole export, and builds
  nothing, when any declared journey in any locale it declares is

    * **unapproved**: the lock names no run for it;
    * **stale**: its declaration hash differs from the approved run's, or the run
      is from another build than the one the lock pins;
    * **altered**: an approved file differs from the hash the lock records, the
      lock entry disagrees with the approved manifest, or that manifest no longer
      passes approval's checks;
    * **drifted**: its text, or a `ui/1` label, no longer resolves to what the run
      recorded, or no longer resolves at all.

  These are `AshJourneys.Lock.verify/6`'s refusals.

  ## A page

  Front matter (the title, the goal as the description, and the journey, kind,
  locale, version, declaration hash and commit it was approved at), then the goal,
  the steps as a numbered list, and the outcome. A step holds its `say` paragraphs
  with each `ui/1` label in bold, its figures, and its notes as GitHub-style
  alerts (`> [!WARNING]`), which need no word in any language. All text, and every
  label, is for the page's locale (`AshJourneys.L10n`).

  ## Figures

  A figure is published as `<file_sha256>.png`, the digest the lock records for the
  approved file, and the page refers to it by that name. Figures are published as
  approved with one change: the colour a capture paints masked regions in
  (`capture_mask_color/0`) is painted `neutral_color/0`, so published pages show
  quiet grey boxes, not the capture's debug colour. A figure with no masked pixel
  is the approved file's bytes.
  """

  alias AshJourneys.{Info, L10n, Lock, Manifest, Raster}

  @capture_mask {255, 0, 255}
  @neutral {209, 213, 219}

  @typedoc "Pages and figures to write: `path`s are relative to the output directories."
  @type t :: %{
          pages: [%{path: String.t(), markdown: String.t()}],
          figures: [%{file: String.t(), bytes: binary()}]
        }

  @doc "The colour a capture paints masked regions in (Playwright's default, magenta)."
  @spec capture_mask_color() :: {byte(), byte(), byte()}
  def capture_mask_color, do: @capture_mask

  @doc "The colour published pages show masked regions in."
  @spec neutral_color() :: {byte(), byte(), byte()}
  def neutral_color, do: @neutral

  @doc """
  The pages for the `declared` journeys (`AshJourneys.Lock.declared/1`) under the
  project root `root`.

  Options: `:figures_ref`, the path pages use to reach the figures directory
  (default `"../figures"`, for pages at `<locale>/<journey>.md`), and
  `:manifest_opts`, the `AshA2ui.Manifest` options the runs used (`:catalog`).
  """
  @spec pages(Path.t(), Lock.declared(), keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def pages(root, declared, opts \\ []) do
    with {:ok, lock} <- Lock.read(root) do
      units =
        for {id, journey} <- Enum.sort(declared),
            locale <- journey.ir["locales"],
            do: {id, journey, locale}

      case collect(units, fn {id, journey, locale} ->
             page(root, lock, id, journey, locale, opts)
           end) do
        {:ok, built} ->
          {:ok,
           %{
             pages: Enum.map(built, & &1.page),
             figures: built |> Enum.flat_map(& &1.figures) |> Enum.uniq_by(& &1.file)
           }}

        {:error, problems} ->
          {:error, problems}
      end
    end
  end

  @doc "Writes the pages under `out` and the figures under `figures`."
  @spec write!(t(), Path.t(), Path.t()) :: :ok
  def write!(%{pages: pages, figures: figures}, out, figures_dir) do
    for %{path: path, markdown: markdown} <- pages do
      path = Path.join(out, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, markdown)
    end

    File.mkdir_p!(figures_dir)

    for %{file: file, bytes: bytes} <- figures,
        do: File.write!(Path.join(figures_dir, file), bytes)

    :ok
  end

  defp page(root, lock, id, journey, locale, opts) do
    with {:ok, entry} <- approved(root, lock, id, journey, locale, opts),
         {:ok, figures} <- published_figures(root, id, locale, entry),
         {:ok, markdown} <- markdown(journey, locale, entry, opts) do
      {:ok, %{page: %{path: "#{locale}/#{id}.md", markdown: markdown}, figures: figures}}
    end
  end

  # The lock's run for this journey and locale, when it still proves it
  # (`AshJourneys.Lock.verify/6`).
  defp approved(root, lock, id, journey, locale, opts) do
    case Lock.verify(root, lock, id, journey, locale, Keyword.take(opts, [:manifest_opts])) do
      {:ok, entry, _manifest} -> {:ok, entry}
      {:error, _refusal, reasons} -> {:error, Enum.map(reasons, &"#{id} (#{locale}): #{&1}")}
    end
  end

  defp published_figures(root, id, locale, entry) do
    dir = Lock.approved_dir(root, locale, id)

    collect(Enum.sort(entry.figures), fn {key, figure} ->
      bytes = File.read!(Path.join(dir, figure.file))

      case Raster.decode(bytes) do
        {:ok, raster} ->
          {:ok, %{file: figure_file(figure), bytes: neutral(bytes, raster)}}

        {:error, reason} ->
          {:error, ["#{id} (#{locale}): figure #{key} does not decode: #{reason}"]}
      end
    end)
  end

  defp figure_file(%{file_sha256: digest}), do: digest <> ".png"

  defp neutral(bytes, raster) do
    painted = Raster.recolor(raster, @capture_mask, @neutral)
    if painted == raster, do: bytes, else: Raster.encode(painted)
  end

  defp markdown(%{module: module, ir: ir, hash: hash}, locale, entry, opts) do
    backend = Info.gettext(module)
    registry = Info.surface_registry(module)
    ref = Keyword.get(opts, :figures_ref, "../figures")
    manifest_opts = Keyword.get(opts, :manifest_opts, [])
    t = &L10n.text(backend, &1, &2, locale)

    with {:ok, title} <- t.(ir["title"], %{}),
         {:ok, goal} <- t.(ir["goal"], %{}),
         {:ok, outcome} <- t.(ir["outcome"], %{}),
         {:ok, steps} <-
           collect(Enum.with_index(ir["steps"], 1), fn {step, number} ->
             step(
               step,
               number,
               entry,
               ref,
               fn binding -> L10n.label(binding, registry, backend, locale, manifest_opts) end,
               t
             )
           end) do
      front =
        [
          title: title,
          description: goal,
          journey: ir["id"],
          kind: String.replace(ir["kind"], "_", "-"),
          locale: locale,
          version: ir["version"],
          declaration: hash,
          commit: entry.commit
        ]
        |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{Jason.encode!(value)}" end)

      {:ok,
       "---\n#{front}\n---\n\n# #{title}\n\n#{goal}\n\n#{Enum.join(steps, "\n")}\n#{outcome}\n"}
    end
  end

  defp step(step, number, entry, ref, label, t) do
    with {:ok, narration} <-
           collect(step["narration"], fn
             %{"type" => "say"} = say -> say(say, label, t)
             %{"type" => "note"} = note -> note(note, t)
           end) do
      says = for {:say, text} <- narration, do: text
      notes = for {:note, text} <- narration, do: text
      alt = says |> hd() |> String.replace("**", "") |> String.replace(~r/[\[\]\n]/, " ")

      figures =
        for %{"type" => "figure"} = figure <- step["body"] do
          file =
            figure_file(
              Map.fetch!(entry.figures, Manifest.figure_key(step["name"], figure["name"]))
            )

          "![#{alt}](#{ref}/#{file})"
        end

      marker = "#{number}. "
      indent = String.duplicate(" ", String.length(marker))

      body =
        (says ++ figures ++ notes)
        |> Enum.join("\n\n")
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.map_join("\n", fn
          {line, 0} -> marker <> line
          {"", _} -> ""
          {line, _} -> indent <> line
        end)

      {:ok, body <> "\n"}
    end
  end

  defp say(%{"text" => text, "bindings" => bindings}, label, t) do
    with {:ok, labels} <-
           collect(Enum.sort(bindings), fn {name, binding} ->
             with {:ok, label} <- label.(binding),
                  do: {:ok, {String.to_existing_atom(name), "**#{label}**"}}
           end),
         {:ok, text} <- t.(text, Map.new(labels)) do
      {:ok, {:say, text}}
    end
  end

  defp note(%{"kind" => kind, "text" => text}, t) do
    with {:ok, text} <- t.(text, %{}) do
      alert = kind |> String.upcase()

      {:ok,
       {:note,
        "> [!#{alert}]\n" <> (text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1)))}}
    end
  end

  # Runs `fun` on every item and gathers every problem, so one run reports them all.
  defp collect(items, fun) do
    results = Enum.map(items, fun)

    case Enum.flat_map(results, fn
           {:error, problems} -> problems
           {:ok, _} -> []
         end) do
      [] -> {:ok, Enum.map(results, fn {:ok, value} -> value end)}
      problems -> {:error, problems}
    end
  end
end
