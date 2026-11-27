defmodule AshJourneys.ExportTest do
  use ExUnit.Case, async: true

  alias AshJourneys.{Approval, Export, L10n, Lock, Raster}
  alias AshJourneys.Test.{Gettext, Runs, Surfaces}

  @journey "revoke_a_leavers_access"
  @magenta <<255, 0, 255, 255>>

  setup context do
    root = Runs.root(context)
    declared = Runs.declared()
    %{root: root, declared: declared}
  end

  # Every candidate of one run, then approved.
  defp approve!(root, declared, rasters \\ nil) do
    for {id, locale} <- [{@journey, "en"}, {@journey, "fr"}, {"remove_a_person", "en"}] do
      opts = if rasters, do: [rasters: rasters.(id, locale)], else: []
      Runs.write!(root, declared, "r1", id, locale, opts)
    end

    assert {:ok, _report} = Approval.approve(root, "r1", declared)
  end

  defp pages!(root, declared, opts \\ []) do
    assert {:ok, export} = Export.pages(root, declared, opts)
    Map.new(export.pages, &{&1.path, &1.markdown})
  end

  test "an approved journey becomes one page per locale, in that locale", %{
    root: root,
    declared: declared
  } do
    approve!(root, declared)
    pages = pages!(root, declared)

    assert Map.keys(pages) |> Enum.sort() ==
             [
               "en/remove_a_person.md",
               "en/revoke_a_leavers_access.md",
               "fr/revoke_a_leavers_access.md"
             ]

    en = pages["en/revoke_a_leavers_access.md"]
    assert en =~ ~s(title: "Revoke a leaver's access")
    assert en =~ ~s(kind: "how-to")
    assert en =~ ~s(locale: "en")
    assert en =~ "declaration: \"#{declared[@journey].hash}\""
    assert en =~ "1. The person who is leaving is still signed in."
    assert en =~ "2. Open **People** and find the person who is leaving."
    assert en =~ "3. Choose **Deactivate**."
    assert en =~ "> [!WARNING]\n   > The next thing they do in the app sends them to sign in."
    assert String.ends_with?(en, "Their access is revoked.\n")

    fr = pages["fr/revoke_a_leavers_access.md"]
    assert fr =~ ~s(title: "Révoquer l'accès d'une personne qui part")
    assert fr =~ ~s(locale: "fr")
    assert fr =~ "2. Ouvrez **Personnes** et trouvez la personne qui part."
    assert fr =~ "3. Choisissez **Désactiver**."
    refute fr =~ "Deactivate"
    assert String.ends_with?(fr, "Son accès est révoqué.\n")
  end

  test "a tutorial says so", %{root: root, declared: declared} do
    approve!(root, declared)
    assert pages!(root, declared)["en/remove_a_person.md"] =~ ~s(kind: "tutorial")
  end

  test "figures are named by the lock's digest and placed after the step's narration", %{
    root: root,
    declared: declared
  } do
    approve!(root, declared)
    {:ok, lock} = Lock.read(root)
    {:ok, export} = Export.pages(root, declared, figures_ref: "/assets/journeys")
    page = Enum.find(export.pages, &(&1.path == "en/#{@journey}.md")).markdown

    for {_key, figure} <- lock.journeys[@journey]["en"].figures do
      assert page =~ "(/assets/journeys/#{figure.file_sha256}.png)"
      assert Enum.any?(export.figures, &(&1.file == figure.file_sha256 <> ".png"))
    end

    assert page =~
             "2. Open **People** and find the person who is leaving.\n\n   ![Open People and find the person who is leaving.](/assets/journeys/"
  end

  test "a figure with no masked pixel is published as approved, byte for byte", %{
    root: root,
    declared: declared
  } do
    approve!(root, declared)
    {:ok, lock} = Lock.read(root)
    {:ok, export} = Export.pages(root, declared)

    for {_key, figure} <- lock.journeys[@journey]["en"].figures do
      published = Enum.find(export.figures, &(&1.file == figure.file_sha256 <> ".png"))
      approved = File.read!(Path.join(Lock.approved_dir(root, "en", @journey), figure.file))
      assert published.bytes == approved
    end
  end

  test "masked regions are published in a neutral colour, and the approved file is untouched",
       %{root: root, declared: declared} do
    masked = Runs.raster(40, 30, [{3, 3, @magenta}, {4, 3, @magenta}])

    approve!(root, declared, fn id, _locale ->
      Runs.rasters(declared, id, masked)
    end)

    {:ok, lock} = Lock.read(root)
    figure = lock.journeys[@journey]["en"].figures |> Enum.sort() |> hd() |> elem(1)
    approved = File.read!(Path.join(Lock.approved_dir(root, "en", @journey), figure.file))
    {:ok, approved_raster} = Raster.decode(approved)
    assert binary_part(approved_raster.rgba, (3 * 40 + 3) * 4, 4) == @magenta

    {:ok, export} = Export.pages(root, declared)
    published = Enum.find(export.figures, &(&1.file == figure.file_sha256 <> ".png"))
    {:ok, raster} = Raster.decode(published.bytes)

    {r, g, b} = Export.neutral_color()
    assert binary_part(raster.rgba, (3 * 40 + 3) * 4, 4) == <<r, g, b, 255>>
    assert binary_part(raster.rgba, (3 * 40 + 4) * 4, 4) == <<r, g, b, 255>>
    refute :binary.match(raster.rgba, @magenta) != :nomatch
    # Nothing else moved: the pixels around the mask are the capture's.
    assert binary_part(raster.rgba, 0, 4) == binary_part(approved_raster.rgba, 0, 4)
    assert File.read!(Path.join(Lock.approved_dir(root, "en", @journey), figure.file)) == approved
  end

  describe "it refuses, and builds nothing" do
    test "a journey with no approved run", %{root: root, declared: declared} do
      Runs.write!(root, declared, "r1", @journey, "en")
      Runs.write!(root, declared, "r1", @journey, "fr")
      assert {:ok, _} = Approval.approve(root, "r1", declared)

      assert {:error, problems} = Export.pages(root, declared)

      assert problems == [
               "remove_a_person (en): no run is approved; run it, then mix ash_journeys.approve"
             ]
    end

    test "a candidate that was never approved is not read", %{root: root, declared: declared} do
      for locale <- ["en", "fr"], do: Runs.write!(root, declared, "r1", @journey, locale)
      Runs.write!(root, declared, "r1", "remove_a_person", "en")

      assert {:error, problems} = Export.pages(root, declared)
      assert length(problems) == 3
      assert Enum.all?(problems, &(&1 =~ "no run is approved"))
    end

    test "a journey whose declaration changed after its approval", %{
      root: root,
      declared: declared
    } do
      approve!(root, declared)
      changed = put_in(declared, [@journey, :hash], String.duplicate("0", 64))

      assert {:error, problems} = Export.pages(root, changed)

      assert [
               "revoke_a_leavers_access (en): stale; the approved run proves " <> _,
               "revoke_a_leavers_access (fr): stale; the approved run proves " <> _
             ] = problems
    end

    test "an approved file that is no longer the one the lock hashed", %{
      root: root,
      declared: declared
    } do
      approve!(root, declared)
      dir = Lock.approved_dir(root, "fr", @journey)
      File.write!(Path.join(dir, "find_the_person.people.png"), "not the figure")

      assert {:error, [problem]} = Export.pages(root, declared)
      assert problem =~ "find_the_person.people.png is not the file the lock approved"
    end

    test "an approved file that is gone", %{root: root, declared: declared} do
      approve!(root, declared)
      File.rm!(Path.join(Lock.approved_dir(root, "en", @journey), "manifest.json"))

      assert {:error, [problem]} = Export.pages(root, declared)
      assert problem =~ "manifest.json is missing"
    end

    test "an unreadable lock", %{root: root, declared: declared} do
      File.mkdir_p!(Path.dirname(Lock.path(root)))
      File.write!(Lock.path(root), "{")
      assert {:error, [problem]} = Export.pages(root, declared)
      assert problem =~ "not JSON"
    end
  end

  describe "labels" do
    @surface %{"type" => "surface", "surface" => "people"}
    @action %{"type" => "row_action", "surface" => "people", "id" => "people.deactivate"}

    test "come from the surface for the locale" do
      assert L10n.label(@surface, Surfaces, Gettext, "en") == {:ok, "People"}
      assert L10n.label(@surface, Surfaces, Gettext, "fr") == {:ok, "Personnes"}
      assert L10n.label(@action, Surfaces, Gettext, "fr") == {:ok, "Désactiver"}
      assert L10n.label(@action, Surfaces, nil, "fr") == {:ok, "Deactivate"}
    end

    test "an unknown ui() symbol is an error, never a guess" do
      assert {:error, [problem]} =
               L10n.label(%{@action | "id" => "people.nope"}, Surfaces, Gettext, "en")

      assert problem =~ ~s(has no row action "people.nope")

      assert {:error, [problem]} =
               L10n.label(%{@surface | "surface" => "nowhere"}, Surfaces, Gettext, "en")

      assert problem =~ "is not a surface"

      assert {:error, [problem]} =
               L10n.label(%{@surface | "surface" => "home"}, Surfaces, Gettext, "en")

      assert problem =~ "is not an A2UI surface"

      assert {:error, [problem]} =
               L10n.label(
                 %{@surface | "surface" => "not_an_atom_anywhere_7f3a"},
                 Surfaces,
                 Gettext,
                 "en"
               )

      assert problem =~ "is not a surface"
    end
  end

  describe "text" do
    @tag :capture_log
    test "a translation that names a placeholder the journey does not bind is an error" do
      assert {:error, [problem]} =
               L10n.text(
                 Gettext,
                 "Open %{surface} and find the person who is leaving.",
                 %{},
                 "fr"
               )

      assert problem =~ "%{surface} is not bound"
    end

    test "with no backend the msgid is interpolated as written" do
      assert L10n.text(nil, "Open %{surface}.", %{surface: "People"}, "fr") ==
               {:ok, "Open People."}

      assert {:error, [_]} = L10n.text(nil, "Open %{surface}.", %{}, "fr")
    end
  end

  describe "messages" do
    test "are every title, goal, outcome and narration, with the declaring file", %{
      declared: declared
    } do
      messages = L10n.messages(declared)

      assert messages["Revoke a leaver's access"] == ["test/support/offboarding.ex"]

      assert messages["Open %{surface} and find the person who is leaving."] == [
               "test/support/offboarding.ex"
             ]

      assert messages["The next thing they do in the app sends them to sign in."] != nil
      assert messages["Remove a person"] != nil
      # Metadata is the host's, never narration.
      refute Map.has_key?(messages, "C-1")
      refute Map.has_key?(messages, "people_team")
    end

    test "untranslated is every text of a declared locale the catalog does not translate", %{
      declared: declared
    } do
      assert L10n.untranslated(declared, "en") == []

      missing = L10n.untranslated(declared, "fr")
      assert {"remove_a_person", "en", "Remove a person"} in missing

      assert {"revoke_a_leavers_access", "en",
              "Open %{surface} and find the person who is leaving."} in missing

      refute Enum.any?(missing, &(elem(&1, 1) == "fr"))
    end

    test "pot is sorted, escaped and stable", %{declared: declared} do
      pot = L10n.pot(L10n.messages(declared))
      assert pot =~ ~s("Domain: journeys\\n")
      assert pot == L10n.pot(L10n.messages(declared))

      msgids = for [_, id] <- Regex.scan(~r/^msgid "(.+)"$/m, pot), do: id
      assert msgids == Enum.sort(msgids)
    end
  end
end
