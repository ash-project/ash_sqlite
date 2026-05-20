# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.AggregatesTest do
  use AshSqlite.RepoCase, async: false

  require Ash.Query
  alias AshSqlite.Test.{Comment, Post, Rating}

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

  test "pagination returns the count" do
    Ash.Seed.seed!(%Post{title: "foo"})
    Ash.Seed.seed!(%Post{title: "foo"})
    Ash.Seed.seed!(%Post{title: "bar"})

    Post
    |> Ash.Query.page(offset: 1, limit: 1, count: true)
    |> Ash.Query.for_read(:paginated)
    |> Ash.read!()
  end

  test "related scalar aggregates can be loaded" do
    post = create_post!("loaded")
    empty_post = create_post!("empty")

    create_comment!(post, "match", 1)
    create_comment!(post, "other", 4)
    create_comment!(post, "other", 10)

    loaded_post =
      post
      |> Ash.load!([
        :count_of_comments,
        :count_of_popular_comments,
        :count_of_comments_called_match,
        :sum_of_comment_likes,
        :sum_of_comment_likes_called_match,
        :avg_comment_likes,
        :min_comment_likes,
        :max_comment_likes,
        :has_comment_called_match
      ])

    assert loaded_post.count_of_comments == 3
    assert loaded_post.count_of_popular_comments == 0
    assert loaded_post.count_of_comments_called_match == 1
    assert loaded_post.sum_of_comment_likes == 15
    assert loaded_post.sum_of_comment_likes_called_match == 1
    assert loaded_post.avg_comment_likes == 5.0
    assert loaded_post.min_comment_likes == 1
    assert loaded_post.max_comment_likes == 10
    assert loaded_post.has_comment_called_match == true

    empty_post =
      empty_post
      |> Ash.load!([
        :count_of_comments,
        :sum_of_comment_likes,
        :avg_comment_likes,
        :has_comment_called_match
      ])

    assert empty_post.count_of_comments == 0
    assert empty_post.sum_of_comment_likes == nil
    assert empty_post.avg_comment_likes == nil
    assert empty_post.has_comment_called_match == false

    assert [
             %Post{title: "empty", count_of_comments: 0},
             %Post{title: "loaded", count_of_comments: 3}
           ] =
             Post
             |> Ash.Query.load(:count_of_comments)
             |> Ash.Query.sort(:title)
             |> Ash.read!()
  end

  test "relationship filters are applied to loaded aggregates" do
    post = create_post!("relationship filter")

    create_comment!(post, "quiet", 1)
    create_comment!(post, "popular", 11)

    assert %{count_of_popular_comments: 1} =
             Ash.load!(post, :count_of_popular_comments)
  end

  test "resource queries can filter on related aggregates" do
    post = create_post!("with comments")
    create_comment!(post, "match", 1)
    create_comment!(post, "other", 1)

    create_post!("without comments")

    assert [%Post{id: post_id, count_of_comments: 2}] =
             Post
             |> Ash.Query.load(:count_of_comments)
             |> Ash.Query.filter(count_of_comments > 1)
             |> Ash.read!()

    assert post_id == post.id
  end

  test "aggregate join filters are applied on one-hop relationships" do
    post = create_post!("join filter")

    create_comment!(post, "match", 1)
    create_comment!(post, "other", 1)

    assert %{count_of_comments_with_join_filter: 1} =
             Ash.load!(post, :count_of_comments_with_join_filter)
  end

  test "same-path aggregates can use different read action filters" do
    post = create_post!("read action aggregate")

    create_comment!(post, "low", 1)
    create_comment!(post, "high", 10)

    assert %{count_of_comments: 2, count_of_liked_comments: 1} =
             Ash.load!(post, [:count_of_comments, :count_of_liked_comments])
  end

  test "aggregate filters can reference relationships" do
    post = create_post!("related aggregate filter")

    create_comment!(post, "first", 1)
    create_comment!(post, "second", 1)

    assert %{count_of_comments_with_related_filter: 2} =
             Ash.load!(post, :count_of_comments_with_related_filter)
  end

  test "aggregate filters can reference related exists expressions" do
    post = create_post!("related aggregate exists filter")

    create_comment!(post, "first", 1)
    create_comment!(post, "second", 1)

    assert %{count_of_comments_with_related_exists_filter: 2} =
             Ash.load!(post, :count_of_comments_with_related_exists_filter)
  end

  test "aggregate filters over filtered to-many relationship refs do not corrupt siblings" do
    post = create_post!("filtered related aggregate filter")
    popular_comment = create_comment!(post, "popular", 1)
    unpopular_comment = create_comment!(post, "unpopular", 1)

    create_comment_rating!(popular_comment, 10)
    create_comment_rating!(popular_comment, 11)
    create_comment_rating!(unpopular_comment, 1)

    assert %{
             count_of_comments: 2,
             sum_of_comment_likes: 2,
             count_of_comments_with_popular_ratings: 1
           } =
             Ash.load!(post, [
               :count_of_comments,
               :sum_of_comment_likes,
               :count_of_comments_with_popular_ratings
             ])
  end

  test "aggregate filters using parent expressions return a stable unsupported error" do
    post = create_post!("same")
    create_comment!(post, "same", 1)

    assert_raise Ash.Error.Unknown, ~r/parent-dependent aggregate filters/, fn ->
      Ash.load!(post, :count_of_comments_matching_post_title)
    end
  end

  test "parent-dependent aggregate join filters return a stable unsupported error" do
    post = create_post!("parent join")
    create_comment!(post, "parent join", 1)

    assert_raise Ash.Error.Unknown, ~r/parent-dependent join filters/, fn ->
      Ash.load!(post, :count_of_comments_with_parent_join_filter)
    end
  end

  test "aggregate filters that reference aggregates return a stable unsupported error" do
    post = create_post!("aggregate filter")
    create_comment!(post, "comment", 1)

    assert_raise Ash.Error.Unknown, ~r/filters that reference other aggregates/, fn ->
      Ash.load!(post, :count_of_comments_with_aggregate_filter)
    end
  end

  test "multi-hop aggregate relationships return stable unsupported errors" do
    post = create_post!("unsupported relationships")
    create_comment!(post, "comment", 1)

    assert_raise Ash.Error.Unknown, ~r/one relationship/, fn ->
      Ash.load!(post, :count_of_comment_ratings)
    end
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

  defp create_comment_rating!(comment, score) do
    Rating
    |> Ash.Changeset.for_create(:create, %{score: score, resource_id: comment.id})
    |> Ash.Changeset.set_context(%{data_layer: %{table: "comment_ratings"}})
    |> Ash.create!()
  end
end
