# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.UniqAggregateSortTest do
  use AshSqlite.RepoCase, async: false

  alias AshSqlite.Test.Comment
  alias AshSqlite.Test.Post

  require Ash.Query

  setup do
    post = create_post!("post")
    other_post = create_post!("other")

    for {title, likes} <- [{"b", 1}, {"a", 5}, {"b", 9}] do
      create_comment!(post, title, likes)
    end

    # Shares titles with `post`, so deduping must not cross parents.
    for {title, likes} <- [{"a", 2}, {"b", 3}, {"a", 4}] do
      create_comment!(other_post, title, likes)
    end

    %{post: post, other_post: other_post}
  end

  test "uniq? aggregate sorted by the aggregated field still works", %{post: post} do
    assert ["a", "b"] ==
             post |> Ash.load!(:uniq_comment_titles) |> Map.get(:uniq_comment_titles)
  end

  # Sorted by likes desc the titles are b, a, b. Deduping keeps each title's first
  # occurrence, matching a sort followed by `Enum.uniq/1`.
  test "uniq? aggregate sorted by a different field keeps first occurrences in sort order",
       %{post: post, other_post: other_post} do
    titles =
      Post
      |> Ash.Query.load(:uniq_comment_titles_sorted_by_likes)
      |> Ash.read!()
      |> Map.new(&{&1.id, &1.uniq_comment_titles_sorted_by_likes})

    assert titles[post.id] == ["b", "a"]
    assert titles[other_post.id] == ["a", "b"]
  end

  test "uniq? aggregate inherits a sort declared on the relationship", %{post: post} do
    assert ["b", "a"] ==
             post
             |> Ash.load!(:uniq_titles_of_comments_sorted_by_likes)
             |> Map.get(:uniq_titles_of_comments_sorted_by_likes)
  end

  test "uniq? aggregate sorted by a different field respects the aggregate's filter",
       %{post: post, other_post: other_post} do
    assert ["a"] ==
             post
             |> Ash.load!(:uniq_popular_comment_titles_sorted_by_likes)
             |> Map.get(:uniq_popular_comment_titles_sorted_by_likes)

    assert ["a", "b"] ==
             other_post
             |> Ash.load!(:uniq_popular_comment_titles_sorted_by_likes)
             |> Map.get(:uniq_popular_comment_titles_sorted_by_likes)
  end

  defp create_post!(title) do
    Post
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  defp create_comment!(post, title, likes) do
    Comment
    |> Ash.Changeset.for_create(:create, %{title: title, likes: likes})
    |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
    |> Ash.create!()
  end
end
