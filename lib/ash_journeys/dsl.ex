defmodule AshJourneys.Dsl do
  @moduledoc """
  The journey DSL. A module uses it through `AshJourneys.Journeys`.

  A journey's steps reference what the application already declares, and the
  verifiers check every reference when the module compiles:

    * surface ids (`open`, `lands_on`, `ui/1`) against the host's
      `AshJourneys.SurfaceRegistry`;
    * row-action and table ids (`row_action`, `frame: {:table, id}`,
      `ui({:row_action, id})`) against the `AshA2ui.Manifest` of the surface the
      step's persona is on;
    * Ash actions (`expect trace: [{:ash_action, name}]`) against the resource the
      row action runs on.

  They also check the journey on its own terms: personas, bound records, narration,
  placeholders and masks (`AshJourneys.Verifiers.VerifyJourney`).

  Verification errors carry the location of the declaration they are about. Like
  every Spark verifier, they are reported when the module is verified and fail
  `mix compile --warnings-as-errors`.
  """

  alias AshJourneys.Dsl

  @trace_kinds [
    :browser_event,
    :browser_connect,
    :live_mount,
    :handle_event,
    :ash_action,
    :query,
    :job_producer,
    :job_consumer
  ]

  @offset_units [:second, :minute, :hour, :day]

  @doc "The span kinds a trace chain may name, as `AshBrowserTests.Trace` matches them."
  @spec trace_kinds() :: [atom()]
  def trace_kinds, do: @trace_kinds

  @open %Spark.Dsl.Entity{
    name: :open,
    describe: "Opens a surface by its id in the host's surface registry.",
    examples: ["open :users"],
    target: Dsl.Open,
    args: [:surface],
    schema: [
      surface: [type: :atom, required: true, doc: "The surface id."]
    ]
  }

  @row_action %Spark.Dsl.Entity{
    name: :row_action,
    describe: """
    Performs a row action on the row of a bound world record. The id is the
    action's `AshA2ui.Manifest` id (`"<table>.<action>"`) on the surface the
    persona is on.
    """,
    examples: [~S|row_action "people.deactivate", on: :leaver, confirm: true|],
    target: Dsl.RowAction,
    args: [:id],
    schema: [
      id: [type: :string, required: true, doc: "The row action's manifest id."],
      on: [type: :atom, required: true, doc: "The world binding whose row it acts on."],
      confirm: [
        type: :boolean,
        default: false,
        doc: "The action asks for confirmation and the journey confirms it."
      ]
    ]
  }

  @figure %Spark.Dsl.Entity{
    name: :figure,
    describe: """
    A figure captured at this point of the step. `frame` is what it shows: the
    page, the confirmation dialog, a table, or the row of a bound record.
    `highlight` outlines a bound record's row. Every `mask` entry names a region
    the host knows (a request-time label, say) and gives it a fixed width, so
    the masked text cannot move the layout around it.
    """,
    examples: [
      ~S|figure :people, frame: {:table, "people"}, highlight: {:row, :leaver}, mask: [{:as_of, width: "6rem"}]|,
      "figure :confirm, frame: :dialog"
    ],
    target: Dsl.Figure,
    args: [:name],
    schema: [
      name: [type: :atom, required: true, doc: "The figure's name, unique in the step."],
      frame: [
        type:
          {:or,
           [
             {:in, [:page, :dialog]},
             {:tuple, [{:in, [:table]}, :string]},
             {:tuple, [{:in, [:row]}, :atom]}
           ]},
        default: :page,
        doc: "`:page`, `:dialog`, `{:table, table_id}` or `{:row, binding}`."
      ],
      highlight: [
        type: {:tuple, [{:in, [:row]}, :atom]},
        doc: "`{:row, binding}`: the bound record's row is outlined."
      ],
      mask: [
        type: {:list, {:or, [:atom, {:tuple, [:atom, :keyword_list]}]}},
        default: [],
        doc: ~s(Regions to mask, each `{region, width: "6rem"}`.)
      ]
    ]
  }

  @expect %Spark.Dsl.Entity{
    name: :expect,
    describe: """
    What the step must have caused. `trace` is a chain of span kinds the step's
    own spans must contain, in order; `one_correlation` requires them under one
    correlation id, and `audit` requires the audit rows that correlation id wrote.
    `record` checks a bound record's attributes; `lands_on` the surface the
    persona ends up on.
    """,
    examples: [
      "expect trace: [:handle_event, {:ash_action, :deactivate}], one_correlation: true, audit: true",
      "expect record: {:leaver, lifecycle_status: :inactive}",
      "expect lands_on: :sign_in"
    ],
    target: Dsl.Expect,
    schema: [
      trace: [
        type: {:list, {:or, [{:in, @trace_kinds}, {:tuple, [{:in, [:ash_action]}, :atom]}]}},
        default: [],
        doc: "Span kinds, in order. `{:ash_action, name}` names the action."
      ],
      one_correlation: [
        type: :boolean,
        default: false,
        doc: "The traced spans share one correlation id."
      ],
      audit: [
        type: :boolean,
        default: false,
        doc: "The traced correlation id wrote audit rows."
      ],
      record: [
        type: {:tuple, [:atom, :keyword_list]},
        doc: "`{binding, attribute: value}`."
      ],
      lands_on: [type: :atom, doc: "The surface the persona lands on."]
    ]
  }

  @say %Spark.Dsl.Entity{
    name: :say,
    describe: """
    Narration, as a gettext msgid. Each `%{name}` placeholder is bound to a
    `ui/1` reference, resolved per locale when the page is rendered.
    """,
    examples: [~S|say "Open %{surface} and find the person.", surface: ui(:users)|],
    target: Dsl.Say,
    args: [:text, {:optional, :bindings, []}],
    imports: [AshJourneys.Ui],
    schema: [
      text: [type: :string, required: true, doc: "The msgid."],
      bindings: [
        type: :keyword_list,
        default: [],
        doc: "Placeholder name to `ui/1` reference."
      ]
    ]
  }

  @note %Spark.Dsl.Entity{
    name: :note,
    describe: "An aside in the narration.",
    examples: [~S|note :warning, "The next thing they do sends them to sign in."|],
    target: Dsl.Note,
    args: [:kind, :text],
    schema: [
      kind: [type: {:in, [:info, :tip, :warning]}, required: true, doc: "The kind of aside."],
      text: [type: :string, required: true, doc: "The msgid."]
    ]
  }

  @step %Spark.Dsl.Entity{
    name: :step,
    describe: "One step, taken by one persona.",
    examples: [
      """
      step :find_the_person, as: :admin do
        open :users
        say "Open %{surface} and find the person who is leaving.", surface: ui(:users)
        figure :people, frame: {:table, "people"}, highlight: {:row, :leaver}
      end
      """
    ],
    target: Dsl.Step,
    # `as` is an optional argument so that `step :name, as: :persona do … end`, whose
    # `do` block Elixir passes apart from its keywords, reaches the entity at all.
    args: [:name, {:optional, :as}],
    transform: {Dsl.Step, :transform, []},
    entities: [
      body: [@open, @row_action, @figure, @expect],
      narration: [@say, @note]
    ],
    schema: [
      name: [type: :atom, required: true, doc: "The step's name, unique in the journey."],
      as: [
        type: {:or, [:atom, {:keyword_list, [as: [type: :atom, required: true]]}]},
        required: true,
        doc: "The persona taking the step."
      ]
    ]
  }

  @persona %Spark.Dsl.Entity{
    name: :persona,
    describe: "A persona: the name steps use with `as:`, and the host role it signs in as.",
    examples: ["persona :admin, :tenant_admin"],
    target: Dsl.Persona,
    args: [:name, :role],
    schema: [
      name: [type: :atom, required: true, doc: "The persona's name in this journey."],
      role: [type: :atom, required: true, doc: "The host role (see `AshJourneys.Persona`)."]
    ]
  }

  @world %Spark.Dsl.Entity{
    name: :world,
    describe: """
    The world the journey runs in. `packs` are the host's seed packs; `bind`
    names the records the steps refer to; `clock` is the instant displayed seed
    timestamps are pinned to, and `timestamps` gives each bound record's pinned
    attributes as offsets from it.
    """,
    examples: [
      """
      world packs: [:offboarding],
            bind: [admin: {:user, :admin}, leaver: {:user, :leaver}],
            clock: ~U[2026-03-02 09:00:00Z],
            timestamps: [leaver: [created_on: {30, :minute}]]
      """
    ],
    target: Dsl.World,
    schema: [
      packs: [type: {:list, :atom}, default: [], doc: "Seed packs."],
      bind: [
        type: {:list, {:tuple, [:atom, {:tuple, [:atom, {:or, [:atom, :string]}]}]}},
        default: [],
        doc: "Binding name to a host record reference, `{kind, key}`."
      ],
      clock: [type: {:struct, DateTime}, doc: "The instant displayed timestamps are pinned to."],
      timestamps: [
        type:
          {:list,
           {:tuple,
            [
              :atom,
              {:list, {:tuple, [:atom, {:tuple, [:integer, {:in, @offset_units}]}]}}
            ]}},
        default: [],
        doc: "Binding name to `[attribute: {amount, unit}]` offsets from `clock`."
      ]
    ]
  }

  @journey %Spark.Dsl.Entity{
    name: :journey,
    describe: "A typed, versioned claim about how one persona reaches one goal.",
    target: Dsl.Journey,
    args: [:name],
    singleton_entity_keys: [:world],
    entities: [
      personas: [@persona],
      world: [@world],
      steps: [@step]
    ],
    schema: [
      name: [type: :atom, required: true, doc: "The journey's id."],
      version: [type: :pos_integer, required: true, doc: "Bumped when the claim changes."],
      kind: [
        type: {:in, [:tutorial, :how_to]},
        required: true,
        doc: "The Diátaxis kind of page it becomes."
      ],
      title: [type: :string, required: true, doc: "The msgid of its title."],
      goal: [type: :string, required: true, doc: "The msgid of what the persona achieves."],
      outcome: [type: :string, required: true, doc: "The msgid of how it ends."],
      locales: [
        type: {:list, :atom},
        required: true,
        doc: "The locales its documentation is published in."
      ],
      metadata: [
        type: :keyword_list,
        default: [],
        doc: "Opaque, JSON-shaped data for the host. This package never reads it."
      ]
    ]
  }

  @journeys %Spark.Dsl.Section{
    name: :journeys,
    top_level?: true,
    describe: "The journeys this module declares.",
    entities: [@journey]
  }

  use Spark.Dsl.Extension,
    sections: [@journeys],
    verifiers: [
      AshJourneys.Verifiers.VerifyHosts,
      AshJourneys.Verifiers.VerifyJourney,
      AshJourneys.Verifiers.VerifyReferences
    ]
end
