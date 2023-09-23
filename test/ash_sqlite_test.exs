defmodule AshSqliteTest do
  use AshSqlite.RepoCase, async: false

  test "transaction metadata is given to on_transaction_begin" do
    AshSqlite.Test.Post
    |> Ash.Changeset.new(%{title: "title"})
    |> AshSqlite.Test.Api.create!()

    assert_receive %{
      type: :create,
      metadata: %{action: :create, actor: nil, resource: AshSqlite.Test.Post}
    }
  end
end
