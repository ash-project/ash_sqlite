# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.JoinSubquerySortTest do
  @moduledoc """
  A sort declared on the read action behind a relationship must not be carried into
  the join subquery for a `belongs_to`, where the join discards the ordering anyway.
  """
  use AshSqlite.RepoCase, async: false

  alias AshSqlite.Test.Comment
  alias AshSqlite.Test.Post

  require Ash.Query

  defp join_sql(query) do
    {:ok, ecto} = Ash.Query.data_layer_query(query)
    {sql, _params} = AshSqlite.TestRepo.to_sql(:all, ecto)
    sql
  end

  test "belongs_to join subquery does not carry the read action's sort" do
    sql =
      Comment
      |> Ash.Query.new()
      |> Ash.Query.filter(not is_nil(sorted_post.title))
      |> join_sql()

    assert sql =~ ~r/LEFT OUTER JOIN \(SELECT/
    refute sql =~ "ORDER BY"
  end

  test "filtering through the sorted belongs_to still works" do
    post =
      Post
      |> Ash.Changeset.for_create(:create, %{title: "a"})
      |> Ash.create!()

    Comment
    |> Ash.Changeset.for_create(:create, %{title: "comment"})
    |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
    |> Ash.create!()

    assert [%{title: "comment"}] =
             Comment
             |> Ash.Query.filter(sorted_post.title == "a")
             |> Ash.read!()
  end

  test "the sorted read action still sorts when read directly" do
    for title <- ["b", "a"] do
      Post
      |> Ash.Changeset.for_create(:create, %{title: title})
      |> Ash.create!()
    end

    titles =
      Post
      |> Ash.Query.for_read(:sorted_by_title)
      |> Ash.read!()
      |> Enum.map(& &1.title)

    assert titles == ["a", "b"]
  end
end
