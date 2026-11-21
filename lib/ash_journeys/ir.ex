defmodule AshJourneys.Ir do
  @moduledoc """
  The journey IR: a declared journey as plain JSON data, and its content hash.

  Every projection (the runner, the run manifest, the lock, exported pages, in-app
  help) reads the IR rather than the DSL structs, and the hash names exactly the
  declaration a run proved. The IR is JSON already: string keys, and only strings,
  numbers, booleans, `nil`, lists and maps as values, so
  `ir |> Jason.encode!() |> Jason.decode!() == ir`.

  ## The hash

  `hash/1` is the SHA-256, as lowercase hex, of the RFC 8785 (JCS) canonical JSON of
  the IR (`canonical_json/1`). Canonical JSON sorts every object's keys, so the hash
  does not depend on the order options or keyword entries were written in, and
  anyone holding the same declaration can recompute it. Any change to what the
  journey declares, including its narration, gives a different hash. Source
  locations and the declaring module's name are not part of the IR, so moving a
  journey without changing it keeps its hash.

  ## Shape (format 1)

      %{
        "format" => 1,
        "id" => "revoke_a_leavers_access",
        "version" => 1,
        "kind" => "how_to",
        "title" => "…", "goal" => "…", "outcome" => "…",
        "locales" => ["en", "fr"],
        "metadata" => %{"controls" => ["CC6.2"]},
        "personas" => [%{"name" => "admin", "role" => "tenant_admin"}],
        "world" => %{
          "packs" => ["offboarding"],
          "bind" => %{"leaver" => ["user", "leaver"]},
          "clock" => "2026-03-02T09:00:00Z",
          "timestamps" => %{"leaver" => %{"created_on" => 1800}}
        },
        "steps" => [
          %{
            "name" => "deactivate",
            "as" => "admin",
            "surface" => "users",
            "body" => [
              %{"type" => "row_action", "id" => "people.deactivate", "on" => "leaver",
                "confirm" => true, "surface" => "users"},
              %{"type" => "figure", "name" => "confirm", "frame" => %{"type" => "dialog"},
                "highlight" => nil, "mask" => %{}},
              %{"type" => "expect",
                "trace" => [%{"type" => "handle_event"},
                            %{"type" => "ash_action", "action" => "deactivate"}],
                "one_correlation" => true, "audit" => true, "record" => nil,
                "lands_on" => nil}
            ],
            "narration" => [
              %{"type" => "say", "text" => "Choose %{action} and confirm.",
                "bindings" => %{"action" => %{"type" => "row_action",
                                              "id" => "people.deactivate",
                                              "surface" => "users"}}},
              %{"type" => "note", "kind" => "warning", "text" => "…"}
            ]
          }
        ]
      }

  A step's `surface` is the surface its persona is on when it acts: the last surface
  the step opens, or else the one the persona was left on by an earlier step (its
  last `open`, or the surface it `lands_on`). Row actions, table frames and
  row-action labels resolve against it, so the IR names the surface for each.
  Offsets in `timestamps` are seconds after `clock`.
  """

  alias AshJourneys.Dsl.{Expect, Figure, Journey, Note, Open, RowAction, Say, Step, World}
  alias AshJourneys.Ui

  @format 1

  @offset_seconds %{second: 1, minute: 60, hour: 3_600, day: 86_400}

  @typedoc "A journey's IR: JSON data with string keys."
  @type t :: %{String.t() => term()}

  @doc "The IR format version, bumped on any change to the IR's shape."
  @spec format() :: pos_integer()
  def format, do: @format

  @doc "The IR of a declared journey."
  @spec build(Journey.t()) :: t()
  def build(%Journey{} = journey) do
    %{
      "format" => @format,
      "id" => Atom.to_string(journey.name),
      "version" => journey.version,
      "kind" => Atom.to_string(journey.kind),
      "title" => journey.title,
      "goal" => journey.goal,
      "outcome" => journey.outcome,
      "locales" => Enum.map(journey.locales, &Atom.to_string/1),
      "metadata" => json_object(journey.metadata),
      "personas" =>
        Enum.map(journey.personas, &%{"name" => string(&1.name), "role" => string(&1.role)}),
      "world" => world(journey.world),
      "steps" => Enum.map(step_surfaces(journey), fn {step, surface} -> step(step, surface) end)
    }
  end

  @doc "The RFC 8785 canonical JSON of an IR."
  @spec canonical_json(t()) :: String.t()
  def canonical_json(ir), do: Jcs.encode(ir)

  @doc "The SHA-256 of the IR's canonical JSON, as lowercase hex."
  @spec hash(t()) :: String.t()
  def hash(ir), do: :crypto.hash(:sha256, canonical_json(ir)) |> Base.encode16(case: :lower)

  @doc """
  Each step of a journey with the surface its persona is on when it acts (see the
  moduledoc), or `nil` when the persona has opened none.
  """
  @spec step_surfaces(Journey.t()) :: [{Step.t(), atom() | nil}]
  def step_surfaces(%Journey{steps: steps}) do
    {pairs, _on} =
      Enum.map_reduce(steps, %{}, fn %Step{as: persona, body: body} = step, on ->
        opened = for %Open{surface: surface} <- body, do: surface
        landed = for %Expect{lands_on: surface} <- body, surface != nil, do: surface
        surface = List.last(opened, Map.get(on, persona))
        {{step, surface}, Map.put(on, persona, List.last(landed, surface))}
      end)

    pairs
  end

  @doc "An offset declared in `world timestamps:`, in seconds."
  @spec offset_seconds({integer(), atom()}) :: integer()
  def offset_seconds({amount, unit}), do: amount * Map.fetch!(@offset_seconds, unit)

  @doc """
  A metadata value as JSON data: atoms become strings and keyword lists objects.
  Raises `ArgumentError` for anything with no JSON form (a tuple, a struct, a pid).
  """
  @spec json(term()) :: term()
  def json(value) when is_nil(value) or is_boolean(value) or is_binary(value), do: value
  def json(value) when is_number(value), do: value
  def json(value) when is_atom(value), do: Atom.to_string(value)

  def json([{key, _} | _] = list) when is_atom(key) do
    if Keyword.keyword?(list), do: json_object(list), else: Enum.map(list, &json/1)
  end

  def json(list) when is_list(list), do: Enum.map(list, &json/1)

  def json(%{__struct__: struct}),
    do: raise(ArgumentError, "a #{inspect(struct)} has no JSON form; write its JSON data")

  def json(map) when is_map(map), do: json_object(map)
  def json(other), do: raise(ArgumentError, "#{inspect(other)} has no JSON form")

  defp json_object(entries) do
    Map.new(entries, fn
      {key, value} when is_atom(key) or is_binary(key) ->
        {to_string(key), json(value)}

      {key, _value} ->
        raise ArgumentError, "a key must be an atom or a string, got #{inspect(key)}"
    end)
  end

  defp world(nil), do: nil

  defp world(%World{} = world) do
    %{
      "packs" => Enum.map(world.packs, &Atom.to_string/1),
      "bind" =>
        Map.new(world.bind, fn {name, {kind, key}} ->
          {string(name), [string(kind), string(key)]}
        end),
      "clock" => world.clock && DateTime.to_iso8601(world.clock),
      "timestamps" =>
        Map.new(world.timestamps, fn {name, pins} ->
          {string(name),
           Map.new(pins, fn {attr, offset} -> {string(attr), offset_seconds(offset)} end)}
        end)
    }
  end

  defp step(%Step{} = step, surface) do
    %{
      "name" => string(step.name),
      "as" => string(step.as),
      "surface" => string(surface),
      "body" => Enum.map(step.body, &body(&1, surface)),
      "narration" => Enum.map(step.narration, &narration(&1, surface))
    }
  end

  defp body(%Open{surface: surface}, _on), do: %{"type" => "open", "surface" => string(surface)}

  defp body(%RowAction{} = action, on) do
    %{
      "type" => "row_action",
      "id" => action.id,
      "on" => string(action.on),
      "confirm" => action.confirm,
      "surface" => string(on)
    }
  end

  defp body(%Figure{} = figure, on) do
    %{
      "type" => "figure",
      "name" => string(figure.name),
      "frame" => frame(figure.frame, on),
      "highlight" => highlight(figure.highlight),
      "mask" => Map.new(figure.mask, &mask/1)
    }
  end

  defp body(%Expect{} = expect, _on) do
    %{
      "type" => "expect",
      "trace" => Enum.map(expect.trace, &trace/1),
      "one_correlation" => expect.one_correlation,
      "audit" => expect.audit,
      "record" => record(expect.record),
      "lands_on" => string(expect.lands_on)
    }
  end

  defp narration(%Say{text: text, bindings: bindings}, on) do
    %{
      "type" => "say",
      "text" => text,
      "bindings" => Map.new(bindings, fn {name, ref} -> {string(name), ui(ref, on)} end)
    }
  end

  defp narration(%Note{kind: kind, text: text}, _on),
    do: %{"type" => "note", "kind" => string(kind), "text" => text}

  defp frame(kind, _on) when kind in [:page, :dialog], do: %{"type" => string(kind)}

  defp frame({:table, table}, on),
    do: %{"type" => "table", "table" => table, "surface" => string(on)}

  defp frame({:row, binding}, _on), do: %{"type" => "row", "binding" => string(binding)}

  defp highlight(nil), do: nil
  defp highlight({:row, binding}), do: %{"type" => "row", "binding" => string(binding)}

  defp mask({region, opts}) when is_list(opts),
    do: {string(region), %{"width" => Keyword.get(opts, :width)}}

  defp mask(region), do: {string(region), %{"width" => nil}}

  defp trace({:ash_action, action}), do: %{"type" => "ash_action", "action" => string(action)}
  defp trace(kind), do: %{"type" => string(kind)}

  defp record(nil), do: nil

  defp record({binding, attributes}),
    do: %{"binding" => string(binding), "attributes" => json_object(attributes)}

  defp ui(%Ui{target: {:row_action, id}}, on),
    do: %{"type" => "row_action", "id" => id, "surface" => string(on)}

  defp ui(%Ui{target: surface}, _on), do: %{"type" => "surface", "surface" => string(surface)}
  defp ui(other, _on), do: json(other)

  defp string(nil), do: nil
  defp string(value) when is_atom(value), do: Atom.to_string(value)
  defp string(value) when is_binary(value), do: value
end
