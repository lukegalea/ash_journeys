defmodule AshJourneys.Verifiers.VerifyJourney do
  @moduledoc """
  Checks each journey on its own terms, without asking the host:

    * journey names are unique in the module, locales are given, and the metadata is
      JSON data;
    * persona and step names are unique, and every step's `as:` names a persona;
    * every step has narration (a `say`), and each `say`'s `%{name}` placeholders
      and its `ui/1` bindings match one to one;
    * every binding a step names (`on:`, `{:row, binding}`, `expect record:`) is
      bound by the world, and every `timestamps` entry pins a bound record against
      a `clock`;
    * figure names are unique in their step, a `:dialog` frame follows a row
      action declared `confirm: true`, and every mask has a fixed-width box;
    * every `expect` expects something, and `one_correlation` and `audit` qualify a
      trace.
  """

  use Spark.Dsl.Verifier

  alias AshJourneys.Dsl.{Expect, Figure, Journey, RowAction, Say, Step, World}
  alias AshJourneys.{Info, Ir, Ui}
  alias AshJourneys.Verifiers.Errors

  @placeholder ~r/%\{(\w+)\}/
  @css_length ~r/\A\d+(\.\d+)?(px|rem|em|ch)\z/

  @impl true
  def verify(dsl_state) do
    journeys = Info.journeys(dsl_state)

    repeated =
      journeys
      |> Enum.group_by(& &1.name)
      |> Enum.flat_map(fn {name, [_first | repeats]} ->
        for journey <- repeats do
          Errors.error(
            dsl_state,
            journey,
            [name],
            "journey #{inspect(name)} is declared more than once"
          )
        end
      end)

    (repeated ++ Enum.flat_map(journeys, &journey(dsl_state, &1)))
    |> Errors.result()
  end

  defp journey(dsl, %Journey{} = journey) do
    personas = MapSet.new(journey.personas, & &1.name)
    bound = bound(journey.world)

    Enum.concat([
      header(dsl, journey),
      duplicates(dsl, journey, journey.personas, "persona"),
      duplicates(dsl, journey, journey.steps, "step"),
      world(dsl, journey, bound),
      Enum.flat_map(journey.steps, &step(dsl, journey, &1, personas, bound))
    ])
  end

  defp header(dsl, journey) do
    locales =
      if journey.locales == [],
        do: [err(dsl, journey, journey, [], "journey #{inspect(journey.name)} names no locales")],
        else: []

    metadata =
      try do
        Ir.json(journey.metadata)
        []
      rescue
        e in ArgumentError ->
          [err(dsl, journey, journey, [], "metadata must be JSON data: #{Exception.message(e)}")]
      end

    locales ++ metadata
  end

  defp duplicates(dsl, journey, entities, kind) do
    entities
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn
      {_name, [_one]} ->
        []

      {name, [_first | repeats]} ->
        Enum.map(repeats, fn entity ->
          err(dsl, journey, entity, [], "#{kind} #{inspect(name)} is declared more than once")
        end)
    end)
  end

  defp bound(nil), do: MapSet.new()
  defp bound(%World{bind: bind}), do: MapSet.new(bind, fn {name, _ref} -> name end)

  defp world(_dsl, %Journey{world: nil}, _bound), do: []

  defp world(dsl, journey, bound) do
    %World{timestamps: timestamps, clock: clock} = world = journey.world

    unbound =
      for {name, _pins} <- timestamps, name not in bound do
        err(
          dsl,
          journey,
          world,
          [:world],
          "timestamps pins #{inspect(name)}, which `bind` does not bind"
        )
      end

    clockless =
      if timestamps != [] and is_nil(clock),
        do: [
          err(
            dsl,
            journey,
            world,
            [:world],
            "timestamps are offsets from `clock`; give the world a clock"
          )
        ],
        else: []

    unbound ++ clockless
  end

  defp step(dsl, journey, %Step{} = step, personas, bound) do
    path = [:step, step.name]

    persona =
      if step.as in personas,
        do: [],
        else: [
          err(dsl, journey, step, path, """
          step #{inspect(step.name)} is taken as #{inspect(step.as)}, which is not a persona of this \
          journey (#{inspect(MapSet.to_list(personas))})\
          """)
        ]

    narration =
      if Enum.any?(step.narration, &match?(%Say{}, &1)),
        do: [],
        else: [
          err(dsl, journey, step, path, """
          step #{inspect(step.name)} has no narration; give it a `say` that tells the reader what \
          happens\
          """)
        ]

    Enum.concat([
      persona,
      narration,
      duplicates(dsl, journey, for(%Figure{} = figure <- step.body, do: figure), "figure"),
      Enum.flat_map(step.narration, &say(dsl, journey, path, &1)),
      body(dsl, journey, path, step.body, bound)
    ])
  end

  defp say(dsl, journey, path, %Say{text: text, bindings: bindings} = say) do
    placeholders = @placeholder |> Regex.scan(text, capture: :all_but_first) |> List.flatten()
    placeholders = MapSet.new(placeholders)
    names = MapSet.new(bindings, fn {name, _ref} -> Atom.to_string(name) end)

    unbound =
      for name <- MapSet.difference(placeholders, names) do
        err(dsl, journey, say, path, "say #{inspect(text)} has no binding for %{#{name}}")
      end

    unused =
      for name <- MapSet.difference(names, placeholders) do
        err(dsl, journey, say, path, "say #{inspect(text)} binds #{name}, which it never uses")
      end

    not_ui =
      for {name, ref} <- bindings, not match?(%Ui{}, ref) do
        err(
          dsl,
          journey,
          say,
          path,
          "say binds #{inspect(name)} to #{inspect(ref)}; bind it to ui/1"
        )
      end

    unbound ++ unused ++ not_ui
  end

  defp say(_dsl, _journey, _path, _note), do: []

  defp body(dsl, journey, path, body, bound) do
    {errors, _confirmed?} =
      Enum.flat_map_reduce(body, false, fn entity, confirmed? ->
        confirmed? = confirmed? or match?(%RowAction{confirm: true}, entity)
        {entry(dsl, journey, path, entity, bound, confirmed?), confirmed?}
      end)

    errors
  end

  defp entry(dsl, journey, path, %RowAction{} = action, bound, _confirmed?),
    do: binding(dsl, journey, path, action, action.on, bound)

  defp entry(dsl, journey, path, %Figure{} = figure, bound, confirmed?) do
    rows = for {:row, name} <- [figure.frame, figure.highlight], do: name

    dialog =
      if figure.frame == :dialog and not confirmed?,
        do: [
          err(dsl, journey, figure, path, """
          figure #{inspect(figure.name)} frames a dialog, but no row action before it in this step \
          is declared `confirm: true`\
          """)
        ],
        else: []

    Enum.concat([
      Enum.flat_map(rows, &binding(dsl, journey, path, figure, &1, bound)),
      dialog,
      masks(dsl, journey, path, figure)
    ])
  end

  defp entry(dsl, journey, path, %Expect{} = expect, bound, _confirmed?) do
    nothing =
      if expect.trace == [] and is_nil(expect.record) and is_nil(expect.lands_on) and
           not expect.audit,
         do: [
           err(
             dsl,
             journey,
             expect,
             path,
             "expect expects nothing; give it a trace, record or lands_on"
           )
         ],
         else: []

    qualifiers =
      for option <- [:one_correlation, :audit], Map.fetch!(expect, option), expect.trace == [] do
        err(
          dsl,
          journey,
          expect,
          path,
          "expect #{option}: true qualifies a trace; give it a `trace`"
        )
      end

    record =
      case expect.record do
        {name, _attributes} -> binding(dsl, journey, path, expect, name, bound)
        nil -> []
      end

    nothing ++ qualifiers ++ record
  end

  defp entry(_dsl, _journey, _path, _open, _bound, _confirmed?), do: []

  defp masks(dsl, journey, path, %Figure{name: name, mask: masks} = figure) do
    duplicates =
      masks
      |> Enum.map(&region/1)
      |> Enum.frequencies()
      |> Enum.flat_map(fn
        {_region, 1} ->
          []

        {region, _n} ->
          [
            err(
              dsl,
              journey,
              figure,
              path,
              "figure #{inspect(name)} masks #{inspect(region)} twice"
            )
          ]
      end)

    duplicates ++ Enum.flat_map(masks, &mask(dsl, journey, path, figure, &1))
  end

  defp region({region, _opts}), do: region
  defp region(region), do: region

  defp mask(dsl, journey, path, figure, {region, opts}) do
    width = Keyword.get(opts, :width)

    cond do
      Keyword.keys(opts) -- [:width] != [] ->
        [
          err(
            dsl,
            journey,
            figure,
            path,
            "mask #{inspect(region)} takes only `width`, got #{inspect(opts)}"
          )
        ]

      is_binary(width) and width =~ @css_length ->
        []

      true ->
        [no_size(dsl, journey, path, figure, region)]
    end
  end

  defp mask(dsl, journey, path, figure, region), do: [no_size(dsl, journey, path, figure, region)]

  defp no_size(dsl, journey, path, figure, region) do
    err(dsl, journey, figure, path, """
    figure #{inspect(figure.name)} masks #{inspect(region)} without a fixed-width box; a masked \
    value whose width varies still moves the layout around it. Write \
    {#{inspect(region)}, width: "6rem"} (a width in px, rem, em or ch)\
    """)
  end

  defp binding(dsl, journey, path, entity, name, bound) do
    if name in bound,
      do: [],
      else: [
        err(dsl, journey, entity, path, """
        #{inspect(name)} is not bound by the world; bind it with \
        `world bind: [#{name}: {kind, key}]`\
        """)
      ]
  end

  defp err(dsl, journey, entity, path, message),
    do: Errors.error(dsl, entity, [journey.name | path], message)
end
