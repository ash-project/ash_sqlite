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

  test "resource queries can sort by related aggregates" do
    one_comment = create_post!("one comment")
    two_comments = create_post!("two comments")
    no_comments = create_post!("no comments")

    create_comment!(one_comment, "only", 1)
    create_comment!(two_comments, "first", 1)
    create_comment!(two_comments, "second", 1)

    assert [
             %Post{id: two_comments_id, count_of_comments: 2},
             %Post{id: one_comment_id, count_of_comments: 1},
             %Post{id: no_comments_id, count_of_comments: 0}
           ] =
             Post
             |> Ash.Query.load(:count_of_comments)
             |> Ash.Query.sort(count_of_comments: :desc)
             |> Ash.read!()

    assert two_comments_id == two_comments.id
    assert one_comment_id == one_comment.id
    assert no_comments_id == no_comments.id
  end

  test "aggregate sorting works with pagination and aggregate filters" do
    one_comment = create_post!("one comment")
    two_comments = create_post!("two comments")
    three_comments = create_post!("three comments")
    create_post!("no comments")

    create_comment!(one_comment, "only", 1)
    create_comment!(two_comments, "first", 1)
    create_comment!(two_comments, "second", 1)
    create_comment!(three_comments, "first", 1)
    create_comment!(three_comments, "second", 1)
    create_comment!(three_comments, "third", 1)

    assert [%Post{id: two_comments_id, count_of_comments: 2}] =
             Post
             |> Ash.Query.load(:count_of_comments)
             |> Ash.Query.filter(count_of_comments > 0)
             |> Ash.Query.sort(count_of_comments: :desc)
             |> Ash.Query.limit(1)
             |> Ash.Query.offset(1)
             |> Ash.read!()

    assert two_comments_id == two_comments.id
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

  test "resource queries can filter and sort on related aggregates without loading them" do
    one_comment = create_post!("one unloaded comment")
    two_comments = create_post!("two unloaded comments")
    create_post!("no unloaded comments")

    create_comment!(one_comment, "only", 1)
    create_comment!(two_comments, "first", 1)
    create_comment!(two_comments, "second", 1)

    assert [%Post{id: two_comments_id}, %Post{id: one_comment_id}] =
             Post
             |> Ash.Query.filter(count_of_comments > 0)
             |> Ash.Query.sort(count_of_comments: :desc)
             |> Ash.read!()

    assert two_comments_id == two_comments.id
    assert one_comment_id == one_comment.id
  end

  test "list loads related aggregates" do
    post = create_post!("list load")
    empty_post = create_post!("list load empty")

    create_comment!(post, "first", 1)
    create_comment!(post, "second", 1)

    assert [
             %Post{id: post_id, count_of_comments: 2},
             %Post{id: empty_post_id, count_of_comments: 0}
           ] = Ash.load!([post, empty_post], :count_of_comments)

    assert post_id == post.id
    assert empty_post_id == empty_post.id
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

  test "calculations can reference related aggregates" do
    post = create_post!("with aggregate calculation", %{score: 3})
    empty_post = create_post!("without aggregate calculation", %{score: 7})

    create_comment!(post, "first", 4)
    create_comment!(post, "second", 6)

    assert [
             %Post{
               id: post_id,
               has_comments: true,
               comment_likes_with_score: 13
             },
             %Post{
               id: empty_post_id,
               has_comments: false,
               comment_likes_with_score: 7
             }
           ] =
             Post
             |> Ash.Query.load([:has_comments, :comment_likes_with_score])
             |> Ash.Query.sort(comment_likes_with_score: :desc)
             |> Ash.read!()

    assert post_id == post.id
    assert empty_post_id == empty_post.id
  end

  defp create_post!(title, attrs \\ %{}) do
    Post
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :title, title))
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
