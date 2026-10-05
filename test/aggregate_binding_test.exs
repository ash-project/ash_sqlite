# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.AggregateBindingTest do
  use AshSqlite.RepoCase, async: false

  require Ash.Query

  alias AshSqlite.Test.{Comment, Post, Rating}

  test "a related aggregate filter correlates with the joined resource" do
    rated_post = post!("rated")
    unrated_post = post!("unrated")
    rated_comment = comment!(rated_post, 1)
    comment!(unrated_post, 1)
    refute rated_comment.id == rated_post.id

    rate!(rated_comment)

    assert [result] =
             Post
             |> Ash.Query.filter(comments.count_of_ratings > 0)
             |> Ash.read!()

    assert result.id == rated_post.id
  end

  test "the same aggregate through two relationship paths is not reused across paths" do
    ordinary_rated = post!("ordinary rated")
    ordinary_rated |> comment!(1) |> rate!()
    comment!(ordinary_rated, 20)

    popular_rated = post!("popular rated")
    popular_rated |> comment!(20) |> rate!()

    assert [result] =
             Post
             |> Ash.Query.filter(
               comments.count_of_ratings > 0 and popular_comments.count_of_ratings == 0
             )
             |> Ash.read!()

    assert result.id == ordinary_rated.id
  end

  test "a string-named loaded aggregate retains its public name" do
    post = post!("string name")
    comment!(post, 1)
    comment!(post, 2)

    assert [result] =
             Post
             |> Ash.Query.aggregate("comment_count", :count, :comments)
             |> Ash.read!()

    assert result.aggregates["comment_count"] == 2
  end

  test "same-named aggregates with different filters keep distinct results" do
    post = post!("filters")
    comment!(post, 1)
    comment!(post, 10)
    comment!(post, 20)

    low = aggregate!(:count, :low_count, filter: [likes: [less_than: 5]])
    high = aggregate!(:count, :high_count, filter: [likes: [greater_than: 5]])

    assert %{low_count: 1, high_count: 2} = attach_and_run([low, high])
  end

  test "same-named first aggregates with different sorts keep distinct results" do
    post = post!("sorts")
    comment!(post, 1)
    comment!(post, 10)

    first = aggregate!(:first, :lowest, sort: [likes: :asc])
    last = aggregate!(:first, :highest, sort: [likes: :desc])

    assert %{lowest: 1, highest: 10} = attach_and_run([first, last])
  end

  test "an identical aggregate reuses its join when selected a second time" do
    post = post!("reused")
    comment!(post, 1)
    aggregate = aggregate!(:count, :first_count, [])

    query = attach([aggregate])
    {:ok, selected_again} = add_aggregate(query, %{aggregate | load: :second_count})

    assert length(selected_again.joins) == length(query.joins)
    assert %{first_count: 1, second_count: 1} = TestRepo.one!(selected_again)
  end

  defp aggregate!(kind, load, query_opts) do
    {:ok, aggregate} =
      Ash.Query.Aggregate.new(Post, :same_name, kind,
        path: [:comments],
        field: if(kind == :first, do: :likes),
        query: Ash.Query.build(Comment, query_opts)
      )

    %{aggregate | load: load}
  end

  defp attach_and_run(aggregates) do
    aggregates |> attach() |> TestRepo.one!()
  end

  defp attach(aggregates) do
    {:ok, query} = Ash.Query.data_layer_query(Ash.Query.new(Post))
    query = query |> Ecto.Query.exclude(:select) |> select(%{})

    Enum.reduce(aggregates, query, fn aggregate, query ->
      {:ok, query} = add_aggregate(query, aggregate)

      query
    end)
  end

  defp add_aggregate(query, aggregate) do
    AshSql.Aggregate.add_aggregates(
      query,
      [aggregate],
      Post,
      true,
      query.__ash_bindings__.root_binding
    )
  end

  defp rate!(comment) do
    Rating
    |> Ash.Changeset.for_create(:create, %{score: 5, resource_id: comment.id})
    |> Ash.Changeset.set_context(%{data_layer: %{table: "comment_ratings"}})
    |> Ash.create!()
  end

  defp post!(title) do
    Post |> Ash.Changeset.for_create(:create, %{title: title}) |> Ash.create!()
  end

  defp comment!(post, likes) do
    Comment
    |> Ash.Changeset.for_create(:create, %{title: "comment", likes: likes})
    |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
    |> Ash.create!()
  end
end
