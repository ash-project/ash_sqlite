# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.PolymorphismTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Post, Rating}

  require Ash.Query

  test "you can create related data" do
    Post
    |> Ash.Changeset.for_create(:create, rating: %{score: 10})
    |> Ash.create!()

    assert [%{score: 10}] =
             Rating
             |> Ash.Query.set_context(%{data_layer: %{table: "post_ratings"}})
             |> Ash.read!()
  end

  test "you can read related data" do
    Post
    |> Ash.Changeset.for_create(:create, rating: %{score: 10})
    |> Ash.create!()

    assert [%{score: 10}] =
             Post
             |> Ash.Query.load(:ratings)
             |> Ash.read_one!()
             |> Map.get(:ratings)
  end
end
