defmodule Mix.Tasks.AshJourneysExportTest do
  # The tasks read the working directory and the application environment.
  use ExUnit.Case, async: false

  alias AshJourneys.Test.Runs

  @journey "revoke_a_leavers_access"

  setup context do
    root = Runs.root(context)
    previous = Application.get_env(:ash_journeys, :journeys)
    Application.put_env(:ash_journeys, :journeys, [AshJourneys.Test.Offboarding])
    Mix.shell(Mix.Shell.Process)
    cwd = File.cwd!()
    File.cd!(root)

    on_exit(fn ->
      File.cd!(cwd)
      Mix.shell(Mix.Shell.IO)
      Application.delete_env(:ash_journeys, :people_ui)

      if previous,
        do: Application.put_env(:ash_journeys, :journeys, previous),
        else: Application.delete_env(:ash_journeys, :journeys)
    end)

    %{root: root, declared: Runs.declared()}
  end

  defp output do
    receive do
      {:mix_shell, :info, [message]} -> message
    after
      0 -> flunk("the task printed nothing")
    end
  end

  defp approve!(declared) do
    for {id, locale} <- [{@journey, "en"}, {@journey, "fr"}, {"remove_a_person", "en"}],
        do: Runs.write!(File.cwd!(), declared, "r1", id, locale)

    Mix.Task.rerun("ash_journeys.approve", ["r1"])
    _ = output()
  end

  describe "export" do
    test "writes a page per locale and the figures they refer to", %{declared: declared} do
      approve!(declared)
      Mix.Task.rerun("ash_journeys.export", [])

      assert output() =~ "3 page(s) in docs/journeys"
      en = File.read!("docs/journeys/en/#{@journey}.md")
      assert en =~ "Open **People**"
      assert File.read!("docs/journeys/fr/#{@journey}.md") =~ "Ouvrez **Personnes**"

      [digest | _] =
        Regex.run(~r/\.\.\/figures\/([0-9a-f]{64})\.png/, en, capture: :all_but_first)

      assert File.exists?("docs/journeys/figures/#{digest}.png")
    end

    test "writes where it is told, and pages refer to figures by the path it is told", %{
      declared: declared
    } do
      approve!(declared)

      Mix.Task.rerun("ash_journeys.export", [
        "--out",
        "site/docs",
        "--figures",
        "site/img",
        "--figures-ref",
        "/img"
      ])

      assert output() =~ "in site/docs"
      assert File.read!("site/docs/en/#{@journey}.md") =~ "](/img/"
      assert [_ | _] = Path.wildcard("site/img/*.png")
    end

    test "stops with every reason and writes nothing when a journey is not approved", %{
      declared: declared
    } do
      Runs.write!(File.cwd!(), declared, "r1", @journey, "en")
      Mix.Task.rerun("ash_journeys.approve", ["r1"])
      _ = output()

      error = assert_raise Mix.Error, fn -> Mix.Task.rerun("ash_journeys.export", []) end
      assert error.message =~ "nothing was exported"
      assert error.message =~ "  #{@journey} (fr): no run is approved"
      assert error.message =~ "  remove_a_person (en): no run is approved"
      refute File.exists?("docs/journeys")
    end

    test "stops when a label no longer resolves on its surface", %{declared: declared} do
      approve!(declared)
      Application.put_env(:ash_journeys, :people_ui, nil)

      error = assert_raise Mix.Error, fn -> Mix.Task.rerun("ash_journeys.export", []) end
      assert error.message =~ "is not an A2UI surface"
      refute File.exists?("docs/journeys")
    end

    test "refuses figures without the path pages use for them" do
      assert_raise Mix.Error, ~r/usage: mix ash_journeys.export/, fn ->
        Mix.Task.rerun("ash_journeys.export", ["--figures", "img"])
      end
    end
  end

  describe "gettext.extract" do
    test "--check-translated passes when every declared locale but the default has every text" do
      Mix.Task.rerun("ash_journeys.gettext.extract", ["--check-translated"])
      assert output() =~ "Every journey text has a translation in every declared locale."
    end

    test "--check-translated names each text a declared locale has no translation for" do
      previous = Application.get_env(:gettext, :default_locale)
      Application.put_env(:gettext, :default_locale, "fr")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:gettext, :default_locale, previous),
          else: Application.delete_env(:gettext, :default_locale)
      end)

      error =
        assert_raise Mix.Error, fn ->
          Mix.Task.rerun("ash_journeys.gettext.extract", ["--check-translated"])
        end

      assert error.message =~ "the msgids are written in fr"
      assert error.message =~ ~s(remove_a_person/en: "Remove a person")
      assert error.message =~ ~s(#{@journey}/en: "Revoke a leaver's access")
      refute error.message =~ "/fr:"
    end

    test "--check-translated and --check-up-to-date are not given together" do
      assert_raise Mix.Error, ~r/usage: mix ash_journeys.gettext.extract/, fn ->
        Mix.Task.rerun("ash_journeys.gettext.extract", [
          "--check-translated",
          "--check-up-to-date"
        ])
      end
    end

    test "writes the journeys domain, and --check-up-to-date passes on it" do
      Mix.Task.rerun("ash_journeys.gettext.extract", [])
      assert output() =~ "priv/gettext/journeys.pot: "

      pot = File.read!("priv/gettext/journeys.pot")
      assert pot =~ ~s(msgid "Open %{surface} and find the person who is leaving.")
      assert pot =~ ~r/^#: .*test\/support\/offboarding\.ex$/m

      Mix.Task.rerun("ash_journeys.gettext.extract", ["--check-up-to-date"])
      assert output() =~ "priv/gettext/journeys.pot is up to date."
    end

    test "--check-up-to-date fails on drift, and on a file that was never written" do
      assert_raise Mix.Error, ~r/priv\/gettext\/journeys.pot is out of date/, fn ->
        Mix.Task.rerun("ash_journeys.gettext.extract", ["--check-up-to-date"])
      end

      Mix.Task.rerun("ash_journeys.gettext.extract", [])
      _ = output()
      pot = File.read!("priv/gettext/journeys.pot")

      for drifted <- [
            String.replace(pot, ~s(msgid "Remove a person"), ~s(msgid "Remove somebody")),
            String.replace(pot, ~r/#: .*\n/, "", global: false),
            pot <> "\nmsgid \"A line nobody says\"\nmsgstr \"\"\n"
          ] do
        File.write!("priv/gettext/journeys.pot", drifted)

        assert_raise Mix.Error, ~r/is out of date/, fn ->
          Mix.Task.rerun("ash_journeys.gettext.extract", ["--check-up-to-date"])
        end
      end
    end

    test "the file's name is the domain" do
      assert_raise Mix.Error, ~r/must be named journeys.pot/, fn ->
        Mix.Task.rerun("ash_journeys.gettext.extract", ["--output", "priv/gettext/other.pot"])
      end
    end
  end
end
