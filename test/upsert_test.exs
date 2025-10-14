# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.UpsertTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.Post

  require Ash.Query

  test "upserting results in the same created_at timestamp, but a new updated_at timestamp" do
    id = Ash.UUID.generate()

    new_post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id,
        title: "title2"
      })
      |> Ash.create!(upsert?: true)

    assert new_post.id == id
    assert new_post.created_at == new_post.updated_at

    updated_post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id,
        title: "title3"
      })
      |> Ash.create!(upsert?: true)

    assert updated_post.id == id
    assert updated_post.created_at == new_post.created_at
    assert updated_post.created_at != updated_post.updated_at
  end

  test "upserting a field with a default sets to the new value" do
    id = Ash.UUID.generate()

    new_post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id,
        title: "title2"
      })
      |> Ash.create!(upsert?: true)

    assert new_post.id == id
    assert new_post.created_at == new_post.updated_at

    updated_post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id,
        title: "title2",
        decimal: Decimal.new(5)
      })
      |> Ash.create!(upsert?: true)

    assert updated_post.id == id
    assert Decimal.equal?(updated_post.decimal, Decimal.new(5))
  end
end
