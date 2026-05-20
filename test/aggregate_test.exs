# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.AggregatesTest do
  use AshSqlite.RepoCase, async: false

  require Ash.Query
  alias AshSqlite.Test.{Author, Comment, Post, PostLink, Profile, Rating}

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

  test "paginated reads can count and load scalar aggregates" do
    create_post!("paged aggregate a")
    page_post = create_post!("paged aggregate b")
    create_post!("paged aggregate c")

    create_comment!(page_post, "first", 1)
    create_comment!(page_post, "second", 1)

    assert %Ash.Page.Offset{
             count: 3,
             limit: 1,
             offset: 1,
             results: [
               %Post{title: "paged aggregate b", count_of_comments: 2}
             ]
           } =
             Post
             |> Ash.Query.for_read(:paginated)
             |> Ash.Query.load(:count_of_comments)
             |> Ash.Query.sort(:title)
             |> Ash.Query.page(offset: 1, limit: 1, count: true)
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

  test "fieldless count aggregates use SQL count star" do
    {:ok, query} =
      Post
      |> Ash.Query.load(:count_of_comments)
      |> Ash.Query.data_layer_query()

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, AshSqlite.TestRepo, query)

    assert sql =~ "count(*)"
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

  test "fieldless count filters over to-many refs count distinct aggregate rows" do
    post = create_post!("distinct related aggregate filter")
    popular_comment = create_comment!(post, "popular", 1)
    unpopular_comment = create_comment!(post, "unpopular", 1)

    create_comment_rating!(popular_comment, 10)
    create_comment_rating!(popular_comment, 11)
    create_comment_rating!(unpopular_comment, 1)

    assert %{count_of_comments_with_popular_ratings: 1} =
             Ash.load!(post, :count_of_comments_with_popular_ratings)
  end

  test "exists filters avoid to-many fanout for sum aggregates" do
    post = create_post!("exists fanout aggregate filter")
    popular_comment = create_comment!(post, "popular", 4)
    unpopular_comment = create_comment!(post, "unpopular", 6)

    create_comment_rating!(popular_comment, 10)
    create_comment_rating!(popular_comment, 11)
    create_comment_rating!(unpopular_comment, 1)

    assert %{sum_of_comment_likes_with_popular_ratings_exists: 4} =
             Ash.load!(post, :sum_of_comment_likes_with_popular_ratings_exists)
  end

  test "fanout-prone aggregate filters return stable unsupported errors" do
    post = create_post!("fanout aggregate filter")
    comment = create_comment!(post, "popular", 1)
    create_comment_rating!(comment, 10)
    create_comment_rating!(comment, 11)

    assert_raise Ash.Error.Unknown, ~r/sum, avg, list, custom, or field-based count/, fn ->
      Ash.load!(post, :sum_of_comment_likes_with_popular_ratings)
    end

    assert_raise Ash.Error.Unknown, ~r/sum, avg, list, custom, or field-based count/, fn ->
      Ash.load!(post, :avg_comment_likes_with_popular_ratings)
    end

    assert_raise Ash.Error.Unknown, ~r/list, custom, or field-based count aggregates/, fn ->
      Ash.load!(post, :comment_titles_with_popular_ratings)
    end

    assert_raise Ash.Error.Unknown, ~r/list, custom, or field-based count aggregates/, fn ->
      Ash.load!(post, :comment_titles_joined_with_popular_ratings)
    end

    assert_raise Ash.Error.Unknown, ~r/list, custom, or field-based count aggregates/, fn ->
      Ash.load!(post, :count_comment_titles_with_popular_ratings)
    end
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

  test "multi-hop aggregate relationships can be loaded through normal paths" do
    post = create_post!("post multi-hop")
    comment = create_comment!(post, "comment", 1)
    create_comment_rating!(comment, 7)

    assert %{count_of_comment_ratings: 1} =
             Ash.load!(post, :count_of_comment_ratings)
  end

  test "first aggregates can be loaded" do
    post = create_post!("first aggregate")
    empty_post = create_post!("first aggregate empty")

    create_comment!(post, nil, 1)
    create_comment!(post, "bbb", 1)
    create_comment!(post, "aaa", 1)
    create_comment!(post, "stuff", 1)

    loaded_post =
      Ash.load!(post, [
        :first_comment,
        :first_comment_nils_first,
        :first_comment_nils_first_called_stuff,
        :first_comment_nils_first_include_nil
      ])

    assert loaded_post.first_comment == "aaa"
    assert loaded_post.first_comment_nils_first == "aaa"
    assert loaded_post.first_comment_nils_first_called_stuff == "stuff"
    assert loaded_post.first_comment_nils_first_include_nil == nil

    assert %{first_comment: nil} = Ash.load!(empty_post, :first_comment)
  end

  test "first aggregates can be sorted and used over belongs_to and multi-hop paths" do
    author = create_author!("Belongs", "To")
    author_post = create_post_for_author!(author, "belongs to first")

    low = create_post!("low first")
    high = create_post!("high first")

    create_comment!(low, "aaa", 1)
    create_comment!(high, "zzz", 1)

    assert [
             %Post{id: low_id, first_comment: "aaa"},
             %Post{id: high_id, first_comment: "zzz"}
           ] =
             Post
             |> Ash.Query.load(:first_comment)
             |> Ash.Query.filter(count_of_comments > 0)
             |> Ash.Query.sort(first_comment: :asc)
             |> Ash.read!()

    assert low_id == low.id
    assert high_id == high.id

    assert %{author_first_name: "Belongs"} = Ash.load!(author_post, :author_first_name)

    comment = create_comment!(high, "rated", 1)
    create_comment_rating!(comment, 3)
    create_comment_rating!(comment, 10)

    assert %{highest_rating: 10} = Ash.load!(high, :highest_rating)
  end

  test "list aggregates can be loaded" do
    post = create_post!("list aggregate")
    empty_post = create_post!("list aggregate empty")

    first = create_comment!(post, "bbb", 1)
    create_comment!(post, nil, 1)
    create_comment!(post, "aaa", 7)
    create_comment!(post, "aaa", 9)

    loaded_post =
      Ash.load!(post, [
        :comment_titles,
        :comment_titles_with_nils,
        :uniq_comment_titles,
        :comment_titles_with_5_likes,
        :comment_ids
      ])

    assert loaded_post.comment_titles == ["aaa", "aaa", "bbb"]
    assert loaded_post.comment_titles_with_nils == ["aaa", "aaa", "bbb", nil]
    assert loaded_post.uniq_comment_titles == ["aaa", "bbb"]
    assert loaded_post.comment_titles_with_5_likes == ["aaa", "aaa"]
    assert first.id in loaded_post.comment_ids

    assert %{comment_titles: []} = Ash.load!(empty_post, :comment_titles)
  end

  test "custom aggregates can use sqlite-specific implementations" do
    post = create_post!("custom aggregate")

    create_comment!(post, "aaa", 2)
    create_comment!(post, "bbb", 3)

    assert %{comment_titles_joined: joined, total_comment_likes_custom: total} =
             Ash.load!(post, [:comment_titles_joined, :total_comment_likes_custom])

    assert joined |> String.split(",") |> Enum.sort() == ["aaa", "bbb"]
    assert total == 5.0
    assert is_float(total)
  end

  test "unrelated aggregates without parent filters can be loaded" do
    first_author = create_author!("first", "author")
    second_author = create_author!("second", "author")

    create_profile!("bbb")
    create_profile!("aaa")
    create_profile!(nil)

    create_post!("scored one", %{score: 2})
    create_post!("scored two", %{score: 3})

    loaded_authors =
      [first_author, second_author]
      |> Ash.load!([
        :total_profiles,
        :total_profiles_plus_one,
        :total_post_score,
        :avg_post_score,
        :min_post_score,
        :max_post_score,
        :has_any_profile,
        :first_profile_description,
        :profile_descriptions,
        :post_titles_joined
      ])

    assert [
             %Author{
               id: first_author_id,
               total_profiles: 3,
               total_profiles_plus_one: 4,
               total_post_score: 5,
               avg_post_score: 2.5,
               min_post_score: 2,
               max_post_score: 3,
               has_any_profile: true,
               first_profile_description: "aaa",
               profile_descriptions: ["aaa", "bbb"]
             } = loaded_first_author,
             %Author{
               id: second_author_id,
               total_profiles: 3,
               total_profiles_plus_one: 4,
               total_post_score: 5,
               avg_post_score: 2.5,
               min_post_score: 2,
               max_post_score: 3,
               has_any_profile: true,
               first_profile_description: "aaa",
               profile_descriptions: ["aaa", "bbb"]
             } = loaded_second_author
           ] = loaded_authors

    assert first_author_id == first_author.id
    assert second_author_id == second_author.id

    assert loaded_first_author.post_titles_joined |> String.split(",") |> Enum.sort() == [
             "scored one",
             "scored two"
           ]

    assert loaded_second_author.post_titles_joined |> String.split(",") |> Enum.sort() == [
             "scored one",
             "scored two"
           ]
  end

  test "unsupported aggregate relationship shapes return stable errors" do
    manual_relationship = Ash.Resource.Info.relationship(Post, :comments_containing_title)
    no_attributes_relationship = Ash.Resource.Info.relationship(Post, :posts_with_matching_title)

    parent_filter_relationship =
      Ash.Resource.Info.relationship(Post, :comments_matching_post_title)

    refute AshSqlite.DataLayer.can?(Post, {:aggregate_relationship, manual_relationship})
    refute AshSqlite.DataLayer.can?(Post, {:aggregate_relationship, no_attributes_relationship})
    refute AshSqlite.DataLayer.can?(Post, {:aggregate_relationship, parent_filter_relationship})
  end

  test "parent-dependent unrelated aggregate filters return a stable unsupported error" do
    author = create_author!("parent", "unrelated")
    create_profile!("parent")

    assert_raise Ash.Error.Unknown, ~r/parent-dependent aggregate filters/, fn ->
      Ash.load!(author, :profiles_matching_first_name)
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

  test "many_to_many scalar aggregates can be loaded" do
    source = create_post!("source", %{score: 5})
    match = create_post!("match", %{score: 2})
    other = create_post!("other", %{score: 6})
    archived = create_post!("archived", %{score: 20})
    empty = create_post!("empty", %{score: 1})

    link_posts!(source, [match, other])
    create_post_link!(source, archived, :archived)

    loaded_source =
      Ash.load!(source, [
        :count_of_linked_posts,
        :sum_of_linked_post_scores,
        :avg_linked_post_score,
        :min_linked_post_score,
        :max_linked_post_score,
        :has_linked_post_called_match
      ])

    assert loaded_source.count_of_linked_posts == 2
    assert loaded_source.sum_of_linked_post_scores == 8
    assert loaded_source.avg_linked_post_score == 4.0
    assert loaded_source.min_linked_post_score == 2
    assert loaded_source.max_linked_post_score == 6
    assert loaded_source.has_linked_post_called_match == true

    loaded_empty =
      Ash.load!(empty, [
        :count_of_linked_posts,
        :sum_of_linked_post_scores,
        :avg_linked_post_score,
        :has_linked_post_called_match
      ])

    assert loaded_empty.count_of_linked_posts == 0
    assert loaded_empty.sum_of_linked_post_scores == nil
    assert loaded_empty.avg_linked_post_score == nil
    assert loaded_empty.has_linked_post_called_match == false
  end

  test "many_to_many aggregates with filters that require joins can be loaded" do
    source = create_post!("source")
    author = create_author!("John", "Doe")
    linked = create_post_for_author!(author, "linked")

    link_posts!(source, [linked])

    assert %{count_of_linked_posts_with_author: 1} =
             Ash.load!(source, :count_of_linked_posts_with_author)
  end

  test "many_to_many aggregate filters that require joins work in parent queries" do
    first_source = create_post!("first source")
    second_source = create_post!("second source")
    create_post!("no links")

    author = create_author!("Jane", "Doe")
    linked_with_author = create_post_for_author!(author, "linked with author")
    linked_without_author = create_post!("linked without author")

    link_posts!(first_source, [linked_with_author, linked_without_author])
    link_posts!(second_source, [linked_with_author])

    assert [
             %Post{id: first_source_id, count_of_linked_posts_with_author: 1},
             %Post{id: second_source_id, count_of_linked_posts_with_author: 1}
           ] =
             Post
             |> Ash.Query.load(:count_of_linked_posts_with_author)
             |> Ash.Query.filter(count_of_linked_posts_with_author > 0)
             |> Ash.Query.sort(title: :asc)
             |> Ash.read!()

    assert first_source_id == first_source.id
    assert second_source_id == second_source.id
  end

  test "many_to_many first and list aggregates can be loaded" do
    source = create_post!("m2m window source")
    empty = create_post!("m2m window empty")
    first = create_post!("bbb")
    second = create_post!("ccc")
    archived = create_post!("aaa")

    link_posts!(source, [second, first])
    create_post_link!(source, archived, :archived)

    assert %{
             first_linked_post_title: "bbb",
             linked_post_titles: ["bbb", "ccc"]
           } =
             Ash.load!(source, [
               :first_linked_post_title,
               :linked_post_titles
             ])

    assert %{
             first_linked_post_title: nil,
             linked_post_titles: []
           } =
             Ash.load!(empty, [
               :first_linked_post_title,
               :linked_post_titles
             ])
  end

  test "many_to_many first and list aggregates with joined filters can be loaded" do
    source = create_post!("m2m joined window source")
    author = create_author!("Window", "Author")
    without_author = create_post!("aaa")
    with_author = create_post_for_author!(author, "bbb")
    with_author_later = create_post_for_author!(author, "ccc")

    link_posts!(source, [without_author, with_author_later, with_author])

    assert %{
             first_linked_post_title_with_author: "bbb",
             linked_post_titles_with_author: ["bbb", "ccc"],
             first_linked_post_title_with_author_join_filter: "bbb",
             linked_post_titles_with_author_join_filter: ["bbb", "ccc"]
           } =
             Ash.load!(source, [
               :first_linked_post_title_with_author,
               :linked_post_titles_with_author,
               :first_linked_post_title_with_author_join_filter,
               :linked_post_titles_with_author_join_filter
             ])
  end

  test "many_to_many custom aggregates can be loaded" do
    source = create_post!("m2m custom source")
    empty = create_post!("m2m custom empty")
    first = create_post!("aaa")
    second = create_post!("bbb")
    archived = create_post!("ccc")

    link_posts!(source, [second, first])
    create_post_link!(source, archived, :archived)

    assert %{linked_post_titles_joined: joined} =
             Ash.load!(source, :linked_post_titles_joined)

    assert joined |> String.split(",") |> Enum.sort() == ["aaa", "bbb"]

    assert %{linked_post_titles_joined: nil} =
             Ash.load!(empty, :linked_post_titles_joined)
  end

  test "many_to_many aggregates can be filtered, sorted and used in calculations" do
    one_link = create_post!("one link", %{score: 1})
    two_links = create_post!("two links", %{score: 2})
    no_links = create_post!("no links", %{score: 3})

    linked_a = create_post!("linked a", %{score: 4})
    linked_b = create_post!("linked b", %{score: 5})

    link_posts!(one_link, [linked_a])
    link_posts!(two_links, [linked_a, linked_b])

    assert [
             %Post{
               id: two_links_id,
               count_of_linked_posts: 2,
               linked_post_score_with_score: 11
             },
             %Post{
               id: one_link_id,
               count_of_linked_posts: 1,
               linked_post_score_with_score: 5
             }
           ] =
             Post
             |> Ash.Query.load([
               :count_of_linked_posts,
               :linked_post_score_with_score
             ])
             |> Ash.Query.filter(count_of_linked_posts > 0)
             |> Ash.Query.sort(count_of_linked_posts: :desc)
             |> Ash.read!()

    assert two_links_id == two_links.id
    assert one_link_id == one_link.id

    assert %{linked_post_score_with_score: 3} =
             Ash.load!(no_links, :linked_post_score_with_score)
  end

  test "aggregate join filters are applied on many_to_many relationships" do
    source = create_post!("m2m join filter source")
    match = create_post!("match")
    other = create_post!("other")

    link_posts!(source, [match, other])

    assert %{count_of_linked_posts_with_join_filter: 1} =
             Ash.load!(source, :count_of_linked_posts_with_join_filter)
  end

  test "multi-hop scalar aggregates can be loaded" do
    author = create_author!("multi", "hop")
    empty_author = create_author!("empty", "author")

    first_post = create_post_for_author!(author, "first post")
    second_post = create_post_for_author!(author, "second post")

    create_comment!(first_post, "match", 1)
    create_comment!(first_post, "other", 4)
    create_comment!(second_post, "other", 10)

    loaded_author =
      Ash.load!(author, [
        :count_of_comments_through_posts,
        :sum_of_comment_likes_through_posts,
        :avg_comment_likes_through_posts,
        :min_comment_likes_through_posts,
        :max_comment_likes_through_posts,
        :has_comment_called_match_through_posts
      ])

    assert loaded_author.count_of_comments_through_posts == 3
    assert loaded_author.sum_of_comment_likes_through_posts == 15
    assert loaded_author.avg_comment_likes_through_posts == 5.0
    assert loaded_author.min_comment_likes_through_posts == 1
    assert loaded_author.max_comment_likes_through_posts == 10
    assert loaded_author.has_comment_called_match_through_posts == true

    loaded_empty =
      Ash.load!(empty_author, [
        :count_of_comments_through_posts,
        :sum_of_comment_likes_through_posts,
        :avg_comment_likes_through_posts,
        :has_comment_called_match_through_posts
      ])

    assert loaded_empty.count_of_comments_through_posts == 0
    assert loaded_empty.sum_of_comment_likes_through_posts == nil
    assert loaded_empty.avg_comment_likes_through_posts == nil
    assert loaded_empty.has_comment_called_match_through_posts == false
  end

  test "multi-hop list and custom aggregates can be loaded" do
    author = create_author!("multi", "list")
    empty_author = create_author!("multi", "list empty")

    first_post = create_post_for_author!(author, "first post")
    second_post = create_post_for_author!(author, "second post")

    create_comment!(first_post, "bbb", 1)
    create_comment!(second_post, "aaa", 1)

    assert %{
             comment_titles_through_posts: ["aaa", "bbb"],
             comment_titles_joined_through_posts: joined
           } =
             Ash.load!(author, [
               :comment_titles_through_posts,
               :comment_titles_joined_through_posts
             ])

    assert joined |> String.split(",") |> Enum.sort() == ["aaa", "bbb"]

    assert %{
             comment_titles_through_posts: [],
             comment_titles_joined_through_posts: nil
           } =
             Ash.load!(empty_author, [
               :comment_titles_through_posts,
               :comment_titles_joined_through_posts
             ])
  end

  test "multi-hop aggregates can be filtered, sorted and used in calculations" do
    one_comment = create_author!("one", "comment")
    two_comments = create_author!("two", "comments")
    no_comments = create_author!("no", "comments")

    one_post = create_post_for_author!(one_comment, "one post")
    two_post = create_post_for_author!(two_comments, "two post")

    create_comment!(one_post, "only", 4)
    create_comment!(two_post, "first", 5)
    create_comment!(two_post, "second", 6)

    assert [
             %Author{
               id: two_comments_id,
               count_of_comments_through_posts: 2,
               comment_likes_through_posts_plus_one: 12
             },
             %Author{
               id: one_comment_id,
               count_of_comments_through_posts: 1,
               comment_likes_through_posts_plus_one: 5
             }
           ] =
             Author
             |> Ash.Query.load([
               :count_of_comments_through_posts,
               :comment_likes_through_posts_plus_one
             ])
             |> Ash.Query.filter(count_of_comments_through_posts > 0)
             |> Ash.Query.sort(count_of_comments_through_posts: :desc)
             |> Ash.read!()

    assert two_comments_id == two_comments.id
    assert one_comment_id == one_comment.id

    assert %{comment_likes_through_posts_plus_one: 1} =
             Ash.load!(no_comments, :comment_likes_through_posts_plus_one)
  end

  test "aggregate join filters are applied on multi-hop relationships" do
    author = create_author!("multi", "join filter")
    public_post = create_post_for_author!(author, "public post", %{public: true})
    private_post = create_post_for_author!(author, "private post", %{public: false})

    create_comment!(public_post, "match", 1)
    create_comment!(public_post, "other", 1)
    create_comment!(private_post, "match", 1)

    loaded_author =
      Ash.load!(author, [
        :count_of_comments_on_public_posts,
        :count_of_comments_called_match_with_join_filter
      ])

    assert loaded_author.count_of_comments_on_public_posts == 2
    assert loaded_author.count_of_comments_called_match_with_join_filter == 2
  end

  test "intermediate read action filters are applied on multi-hop aggregates" do
    author = create_author!("multi", "read action")
    public_post = create_post_for_author!(author, "public action post", %{public: true})
    private_post = create_post_for_author!(author, "private action post", %{public: false})

    create_comment!(public_post, "public", 1)
    create_comment!(private_post, "private", 1)

    assert %{count_of_comments_through_public_posts: 1} =
             Ash.load!(author, :count_of_comments_through_public_posts)
  end

  test "multi-hop scalar aggregates ending in many_to_many relationships can be loaded" do
    author = create_author!("multi", "m2m")
    empty_author = create_author!("empty", "m2m")

    public_post = create_post_for_author!(author, "public post", %{public: true})
    private_post = create_post_for_author!(author, "private post", %{public: false})

    match = create_post!("match", %{score: 2})
    other = create_post!("other", %{score: 6})
    private = create_post!("private", %{score: 10})
    archived = create_post!("archived", %{score: 20})

    link_posts!(public_post, [match, other])
    link_posts!(private_post, [private])
    create_post_link!(private_post, archived, :archived)

    loaded_author =
      Ash.load!(author, [
        :count_of_linked_posts_through_posts,
        :sum_of_linked_post_scores_through_posts,
        :avg_linked_post_score_through_posts,
        :min_linked_post_score_through_posts,
        :max_linked_post_score_through_posts,
        :has_linked_post_called_match_through_posts
      ])

    assert loaded_author.count_of_linked_posts_through_posts == 3
    assert loaded_author.sum_of_linked_post_scores_through_posts == 18
    assert loaded_author.avg_linked_post_score_through_posts == 6.0
    assert loaded_author.min_linked_post_score_through_posts == 2
    assert loaded_author.max_linked_post_score_through_posts == 10
    assert loaded_author.has_linked_post_called_match_through_posts == true

    loaded_empty =
      Ash.load!(empty_author, [
        :count_of_linked_posts_through_posts,
        :sum_of_linked_post_scores_through_posts,
        :avg_linked_post_score_through_posts,
        :has_linked_post_called_match_through_posts
      ])

    assert loaded_empty.count_of_linked_posts_through_posts == 0
    assert loaded_empty.sum_of_linked_post_scores_through_posts == nil
    assert loaded_empty.avg_linked_post_score_through_posts == nil
    assert loaded_empty.has_linked_post_called_match_through_posts == false
  end

  test "multi-hop many_to_many scalar aggregates work in parent queries" do
    one_link = create_author!("one", "m2m")
    two_links = create_author!("two", "m2m")
    create_author!("none", "m2m")

    one_post = create_post_for_author!(one_link, "one post")
    two_post = create_post_for_author!(two_links, "two post")

    linked_a = create_post!("linked a", %{score: 4})
    linked_b = create_post!("linked b", %{score: 5})

    link_posts!(one_post, [linked_a])
    link_posts!(two_post, [linked_a, linked_b])

    assert [
             %Author{
               id: two_links_id,
               count_of_linked_posts_through_posts: 2,
               linked_post_score_through_posts_plus_one: 10
             },
             %Author{
               id: one_link_id,
               count_of_linked_posts_through_posts: 1,
               linked_post_score_through_posts_plus_one: 5
             }
           ] =
             Author
             |> Ash.Query.load([
               :count_of_linked_posts_through_posts,
               :linked_post_score_through_posts_plus_one
             ])
             |> Ash.Query.filter(count_of_linked_posts_through_posts > 0)
             |> Ash.Query.sort(count_of_linked_posts_through_posts: :desc)
             |> Ash.read!()

    assert two_links_id == two_links.id
    assert one_link_id == one_link.id
  end

  test "unsupported multi-hop many_to_many aggregate shapes return stable errors" do
    author = create_author!("multi", "m2m unsupported")
    post = create_post_for_author!(author, "post")
    linked_post = create_post!("linked")

    link_posts!(post, [linked_post])

    assert_raise Ash.Error.Unknown, ~r/multi-hop paths that include many_to_many/, fn ->
      Ash.load!(post, :count_of_comments_through_linked_posts)
    end

    assert_raise Ash.Error.Unknown, ~r/multi-hop paths that include many_to_many/, fn ->
      Ash.load!(author, :linked_post_titles_through_posts)
    end
  end

  defp create_post!(title, attrs \\ %{}) do
    Post
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :title, title))
    |> Ash.create!()
  end

  defp create_author!(first_name, last_name) do
    Author
    |> Ash.Changeset.for_create(:create, %{first_name: first_name, last_name: last_name})
    |> Ash.create!()
  end

  defp create_post_for_author!(author, title, attrs \\ %{}) do
    Post
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :title, title))
    |> Ash.Changeset.manage_relationship(:author, author, type: :append_and_remove)
    |> Ash.create!()
  end

  defp create_profile!(description) do
    Profile
    |> Ash.Changeset.for_create(:create, %{description: description})
    |> Ash.create!()
  end

  defp create_comment!(post, title, likes, attrs \\ %{}) do
    Comment
    |> Ash.Changeset.for_create(:create, Map.merge(attrs, %{title: title, likes: likes}))
    |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
    |> Ash.create!()
  end

  defp create_comment_rating!(comment, score) do
    Rating
    |> Ash.Changeset.for_create(:create, %{score: score, resource_id: comment.id})
    |> Ash.Changeset.set_context(%{data_layer: %{table: "comment_ratings"}})
    |> Ash.create!()
  end

  defp link_posts!(source, destinations) do
    source
    |> Ash.Changeset.new()
    |> Ash.Changeset.manage_relationship(:linked_posts, destinations, type: :append_and_remove)
    |> Ash.update!()
  end

  defp create_post_link!(source, destination, state) do
    PostLink
    |> Ash.Changeset.new()
    |> Ash.Changeset.change_attribute(:state, state)
    |> Ash.Changeset.manage_relationship(:source_post, source, type: :append)
    |> Ash.Changeset.manage_relationship(:destination_post, destination, type: :append)
    |> Ash.create!()
  end
end
