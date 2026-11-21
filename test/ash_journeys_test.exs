defmodule AshJourneysTest do
  use ExUnit.Case, async: true

  test "the package states its governing rule" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(AshJourneys)
    assert doc =~ "a projection may show only what a passing run"
  end

  test "the runtime package depends on no browser driver and no evidence or manual package" do
    {lock, _binding} = Code.eval_file("mix.lock")
    locked = lock |> Map.keys() |> Enum.map(&Atom.to_string/1)

    for forbidden <- [
          "playwright",
          "ash_browser_tests",
          "ash_compliance",
          "ash_paper",
          "ash_evidence"
        ] do
      assert Enum.filter(locked, &String.contains?(&1, forbidden)) == [],
             "#{forbidden} is in mix.lock"
    end
  end
end
