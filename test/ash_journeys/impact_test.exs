defmodule AshJourneys.ImpactTest do
  use ExUnit.Case, async: true

  alias AshJourneys.{Approval, Impact, Lock, Raster}
  alias AshJourneys.Test.Runs

  @journey "revoke_a_leavers_access"
  @people "find_the_person.people"
  @row "deactivate.deactivated"

  setup context do
    root = Runs.root(context)
    declared = Runs.declared()
    Runs.write!(root, declared, "r1", @journey, "en")
    {:ok, _} = Approval.approve(root, "r1", declared)
    %{root: root, declared: declared, lock: File.read!(Lock.path(root))}
  end

  test "renders a changed figure beside the approved one and lists the rest", %{
    root: root,
    declared: declared,
    lock: lock
  } do
    changed = Runs.raster(40, 30, for(x <- 0..39, y <- 0..1, do: {x, y, <<250, 250, 250, 255>>}))
    wobble = Runs.raster(40, 30, [{0, 29, <<30, 40, 60, 255>>}])

    Runs.write!(root, declared, "r2", @journey, "en",
      rasters: %{@people => changed, @row => wobble}
    )

    assert {:ok, %{results: [result]}} = Impact.report(root, "r2", declared)
    assert result.problems == []

    assert [
             {@row, {:within_tolerance, %{pixels: 1}}},
             {@people, {:changed, %{pixels: 80, max_delta: 230}}}
           ] = result.figures

    assert [image] = result.images
    assert image == Path.join([Impact.dir(root, "r2"), @journey, "en", @people <> ".png"])
    assert {:ok, %Raster{width: 136, height: 30}} = Raster.decode(File.read!(image))

    # It approves nothing.
    assert File.read!(Lock.path(root)) == lock
  end

  test "reports added and removed figures, a size change, and every reason approve would refuse",
       %{root: root, declared: declared, lock: lock} do
    taller = Runs.raster(40, 31)

    Runs.write!(root, declared, "r2", @journey, "en",
      rasters: %{@people => taller, @row => Runs.raster()},
      edit: fn manifest ->
        manifest
        |> Map.put(:retries, 1)
        |> Runs.figure(
          "deactivate",
          "deactivated",
          &%{&1 | name: "renamed", file: @row <> ".png"}
        )
      end
    )

    assert {:ok, %{results: [result]}} = Impact.report(root, "r2", declared)
    assert {@people, {:changed, %{size: {{40, 30}, {40, 31}}}}} in result.figures
    assert {"deactivate.renamed", :added} in result.figures
    assert {@row, :removed} in result.figures
    assert Enum.any?(result.problems, &(&1 =~ "the run needed 1 retry"))
    assert Enum.any?(result.problems, &(&1 =~ "did not capture figure deactivated"))

    assert [image] = result.images
    assert {:ok, %Raster{width: 88, height: 31}} = Raster.decode(File.read!(image))
    assert File.read!(Lock.path(root)) == lock
  end

  test "a candidate whose manifest does not read is reported, with no figures", %{
    root: root,
    declared: declared
  } do
    dir = Runs.write!(root, declared, "r2", @journey, "fr")
    File.write!(Path.join(dir, "manifest.json"), "nope")

    assert {:ok, %{results: [result]}} = Impact.report(root, "r2", declared)
    assert result.figures == []
    assert [problem] = result.problems
    assert problem =~ "#{@journey}/fr: manifest: not JSON"
  end
end
