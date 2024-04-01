defmodule AshSqlite.Test.TypeTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.Post

  require Ash.Query

  test "uuids can be used as strings in fragments" do
    uuid = Ash.UUID.generate()

    Post
    |> Ash.Query.filter(fragment("? = ?", id, type(^uuid, :uuid)))
    |> Ash.read!()
  end
end
