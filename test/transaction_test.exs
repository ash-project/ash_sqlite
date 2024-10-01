defmodule AshSqlite.Test.TransactionTest do
  @moduledoc false
  use AshSqlite.RepoCase, async: false

  test "when an after action hook fails, it rolls back the transaction" do
    assert [] =
             AshSqlite.Test.Post
             |> AshSqlite.TestRepo.all()

    assert {:error, _} =
             AshSqlite.Test.Post
             |> Ash.Changeset.for_create(:failing_after_action, %{title: "turtle the title"})
             |> Ash.create()

    assert [] =
             AshSqlite.Test.Post
             |> AshSqlite.TestRepo.all()
  end
end
