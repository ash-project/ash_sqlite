defmodule AshSqlite.AggregatesTest do
  use AshSqlite.RepoCase, async: false

  require Ash.Query
  alias AshSqlite.Test.Post

  test "a count with a filter returns the appropriate value" do
    Ash.Seed.seed!(%Post{title: "foo"})
    Ash.Seed.seed!(%Post{title: "foo"})
    Ash.Seed.seed!(%Post{title: "bar"})

    count =
      Post
      |> Ash.Query.filter(title == "foo")
      |> Ash.count!()

    assert count == 2
  end
end
