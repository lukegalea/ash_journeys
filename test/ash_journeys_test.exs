defmodule AshJourneysTest do
  use ExUnit.Case, async: true

  test "the package states its governing rule" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(AshJourneys)
    assert doc =~ "a projection may show only what a passing run"
  end
end
