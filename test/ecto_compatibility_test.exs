defmodule AshSqlite.EctoCompatibilityTest do
  use AshSqlite.RepoCase, async: false
  require Ash.Query

  test "call Ecto.Repo.insert! via Ash Repo" do
    org =
      %AshSqlite.Test.Organization{name: "The Org"}
      |> AshSqlite.TestRepo.insert!()

    assert org.name == "The Org"
  end
end
