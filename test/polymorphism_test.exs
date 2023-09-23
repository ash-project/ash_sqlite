defmodule AshSqlite.PolymorphismTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Api, Post, Rating}

  require Ash.Query

  test "you can create related data" do
    Post
    |> Ash.Changeset.for_create(:create, rating: %{score: 10})
    |> Api.create!()

    assert [%{score: 10}] =
             Rating
             |> Ash.Query.set_context(%{data_layer: %{table: "post_ratings"}})
             |> Api.read!()
  end

  test "you can read related data" do
    Post
    |> Ash.Changeset.for_create(:create, rating: %{score: 10})
    |> Api.create!()

    assert [%{score: 10}] =
             Post
             |> Ash.Query.load(:ratings)
             |> Api.read_one!()
             |> Map.get(:ratings)
  end
end
