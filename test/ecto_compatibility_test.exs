defmodule AshSqlite.EctoCompatibilityTest do
  use AshSqlite.RepoCase, async: false
  require Ash.Query

  defmodule Schema do
    use Ecto.Schema

    schema "orgs" do
      field(:name, :string)
    end
  end

  test "call Ecto.Repo.insert! via Ash Repo" do
    org =
      %Schema{id: Ash.UUID.generate(), name: "The Org"}
      # |> Ecto.Changeset.cast(%{name: "The Org"}, [:name])
      # |> Ecto.Changeset.validate_required([:name])
      |> AshSqlite.TestRepo.insert!()

    assert org.name == "The Org"
  end
end
