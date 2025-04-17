defmodule AshSqlite.FilterTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Author, Comment, Post}

  require Ash.Query

  describe "with no filter applied" do
    test "with no data" do
      assert [] = Ash.read!(Post)
    end

    test "with data" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "title"})
      |> Ash.create!()

      assert [%Post{title: "title"}] = Ash.read!(Post)
    end
  end

  describe "invalid uuid" do
    test "with an invalid uuid, an invalid error is raised" do
      assert_raise Ash.Error.Invalid, fn ->
        Post
        |> Ash.Query.filter(id == "foo")
        |> Ash.read!()
      end
    end
  end

  describe "with a simple filter applied" do
    test "with no data" do
      results =
        Post
        |> Ash.Query.filter(title == "title")
        |> Ash.read!()

      assert [] = results
    end

    test "with data that matches" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "title"})
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(title == "title")
        |> Ash.read!()

      assert [%Post{title: "title"}] = results
    end

    test "with some data that matches and some data that doesnt" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "title"})
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(title == "no_title")
        |> Ash.read!()

      assert [] = results
    end

    test "with related data that doesn't match" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "title"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "not match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(comments.title == "match")
        |> Ash.read!()

      assert [] = results
    end

    test "with related data two steps away that matches" do
      author =
        Author
        |> Ash.Changeset.for_create(:create, %{first_name: "match"})
        |> Ash.create!()

      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "title"})
        |> Ash.Changeset.manage_relationship(:author, author, type: :append_and_remove)
        |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "title2"})
      |> Ash.Changeset.manage_relationship(:linked_posts, [post], type: :append_and_remove)
      |> Ash.Changeset.manage_relationship(:author, author, type: :append_and_remove)
      |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "not match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.Changeset.manage_relationship(:author, author, type: :append_and_remove)
      |> Ash.create!()

      results =
        Comment
        |> Ash.Query.filter(author.posts.linked_posts.title == "title")
        |> Ash.read!()

      assert [_] = results
    end

    test "with related data that does match" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "title"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(comments.title == "match")
        |> Ash.read!()

      assert [%Post{title: "title"}] = results
    end

    test "with related data that does and doesn't match" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "title"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "not match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(comments.title == "match")
        |> Ash.read!()

      assert [%Post{title: "title"}] = results
    end
  end

  describe "in" do
    test "it properly filters" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "title"})
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "title1"})
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "title2"})
      |> Ash.create!()

      assert [%Post{title: "title1"}, %Post{title: "title2"}] =
               Post
               |> Ash.Query.filter(title in ["title1", "title2"])
               |> Ash.Query.sort(title: :asc)
               |> Ash.read!()
    end
  end

  describe "with a boolean filter applied" do
    test "with no data" do
      results =
        Post
        |> Ash.Query.filter(title == "title" or score == 1)
        |> Ash.read!()

      assert [] = results
    end

    test "with data that doesn't match" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "no title", score: 2})
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(title == "title" or score == 1)
        |> Ash.read!()

      assert [] = results
    end

    test "with data that matches both conditions" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "title", score: 0})
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{score: 1, title: "nothing"})
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(title == "title" or score == 1)
        |> Ash.read!()
        |> Enum.sort_by(& &1.score)

      assert [%Post{title: "title", score: 0}, %Post{title: "nothing", score: 1}] = results
    end

    test "with data that matches one condition and data that matches nothing" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "title", score: 0})
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{score: 2, title: "nothing"})
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(title == "title" or score == 1)
        |> Ash.read!()
        |> Enum.sort_by(& &1.score)

      assert [%Post{title: "title", score: 0}] = results
    end

    test "with related data in an or statement that matches, while basic filter doesn't match" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "doesn't match"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(title == "match" or comments.title == "match")
        |> Ash.read!()

      assert [%Post{title: "doesn't match"}] = results
    end

    test "with related data in an or statement that doesn't match, while basic filter does match" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "match"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "doesn't match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(title == "match" or comments.title == "match")
        |> Ash.read!()

      assert [%Post{title: "match"}] = results
    end

    test "with related data and an inner join condition" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "match"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "match"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(title == comments.title)
        |> Ash.read!()

      assert [%Post{title: "match"}] = results

      results =
        Post
        |> Ash.Query.filter(title != comments.title)
        |> Ash.read!()

      assert [] = results
    end
  end

  describe "accessing embeds" do
    setup do
      Author
      |> Ash.Changeset.for_create(:create,
        bio: %{title: "Dr.", bio: "Strange", years_of_experience: 10}
      )
      |> Ash.create!()

      Author
      |> Ash.Changeset.for_create(:create,
        bio: %{title: "Highlander", bio: "There can be only one."}
      )
      |> Ash.create!()

      :ok
    end

    test "works using simple equality" do
      assert [%{bio: %{title: "Dr."}}] =
               Author
               |> Ash.Query.filter(bio[:title] == "Dr.")
               |> Ash.read!()
    end

    test "works using simple equality for integers" do
      assert [%{bio: %{title: "Dr."}}] =
               Author
               |> Ash.Query.filter(bio[:years_of_experience] == 10)
               |> Ash.read!()
    end

    test "calculations that use embeds can be filtered on" do
      assert [%{bio: %{title: "Dr."}}] =
               Author
               |> Ash.Query.filter(title == "Dr.")
               |> Ash.read!()
    end
  end

  describe "basic expressions" do
    test "basic expressions work" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "match", score: 4})
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "non_match", score: 2})
      |> Ash.create!()

      assert [%{title: "match"}] =
               Post
               |> Ash.Query.filter(score + 1 == 5)
               |> Ash.read!()
    end
  end

  describe "case insensitive fields" do
    test "it matches case insensitively" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "match", category: "FoObAr"})
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{category: "bazbuz"})
      |> Ash.create!()

      assert [%{title: "match"}] =
               Post
               |> Ash.Query.filter(category == "fOoBaR")
               |> Ash.read!()
    end
  end

  describe "exists/2" do
    test "it works with single relationships" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "match"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "abba"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      post2 =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "no_match"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "acca"})
      |> Ash.Changeset.manage_relationship(:post, post2, type: :append_and_remove)
      |> Ash.create!()

      assert [%{title: "match"}] =
               Post
               |> Ash.Query.filter(exists(comments, title == ^"abba"))
               |> Ash.read!()
    end

    test "it works with many to many relationships" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "a"})
        |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "b"})
      |> Ash.Changeset.manage_relationship(:linked_posts, [post], type: :append_and_remove)
      |> Ash.create!()

      assert [%{title: "b"}] =
               Post
               |> Ash.Query.filter(exists(linked_posts, title == ^"a"))
               |> Ash.read!()
    end

    test "it works with join association relationships" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "a"})
        |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "b"})
      |> Ash.Changeset.manage_relationship(:linked_posts, [post], type: :append_and_remove)
      |> Ash.create!()

      assert [%{title: "b"}] =
               Post
               |> Ash.Query.filter(exists(linked_posts, title == ^"a"))
               |> Ash.read!()
    end

    test "it works with nested relationships as the path" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "a"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "comment"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "b"})
      |> Ash.Changeset.manage_relationship(:linked_posts, [post], type: :append_and_remove)
      |> Ash.create!()

      assert [%{title: "b"}] =
               Post
               |> Ash.Query.filter(exists(linked_posts.comments, title == ^"comment"))
               |> Ash.read!()
    end

    test "it works with an `at_path`" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "a"})
        |> Ash.create!()

      other_post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "other_a"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "comment"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "comment"})
      |> Ash.Changeset.manage_relationship(:post, other_post, type: :append_and_remove)
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "b"})
      |> Ash.Changeset.manage_relationship(:linked_posts, [post], type: :append_and_remove)
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "b"})
      |> Ash.Changeset.manage_relationship(:linked_posts, [other_post], type: :append_and_remove)
      |> Ash.create!()

      assert [%{title: "b"}] =
               Post
               |> Ash.Query.filter(
                 linked_posts.title == "a" and
                   linked_posts.exists(comments, title == ^"comment")
               )
               |> Ash.read!()

      assert [%{title: "b"}] =
               Post
               |> Ash.Query.filter(
                 linked_posts.title == "a" and
                   linked_posts.exists(comments, title == ^"comment")
               )
               |> Ash.read!()
    end

    test "it works with nested relationships inside of exists" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "a"})
        |> Ash.create!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "comment"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "b"})
      |> Ash.Changeset.manage_relationship(:linked_posts, [post], type: :append_and_remove)
      |> Ash.create!()

      assert [%{title: "b"}] =
               Post
               |> Ash.Query.filter(exists(linked_posts, comments.title == ^"comment"))
               |> Ash.read!()
    end
  end

  describe "filtering on enum types" do
    test "it allows simple filtering" do
      Post
      |> Ash.Changeset.for_create(:create, status_enum: "open")
      |> Ash.create!()

      assert %{status_enum: :open} =
               Post
               |> Ash.Query.filter(status_enum == ^"open")
               |> Ash.read_one!()
    end

    test "it allows simple filtering without casting" do
      Post
      |> Ash.Changeset.for_create(:create, status_enum_no_cast: "open")
      |> Ash.create!()

      assert %{status_enum_no_cast: :open} =
               Post
               |> Ash.Query.filter(status_enum_no_cast == ^"open")
               |> Ash.read_one!()
    end
  end

  describe "atom filters" do
    test "it works on matches" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "match"})
      |> Ash.create!()

      result =
        Post
        |> Ash.Query.filter(type == :sponsored)
        |> Ash.read!()

      assert [%Post{title: "match"}] = result
    end
  end

  describe "like" do
    test "like builds and matches" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "MaTcH"})
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(like(title, "%aTc%"))
        |> Ash.read!()

      assert [%Post{title: "MaTcH"}] = results

      results =
        Post
        |> Ash.Query.filter(like(title, "%atc%"))
        |> Ash.read!()

      assert [] = results
    end
  end

  describe "ilike" do
    test "ilike builds and matches" do
      Post
      |> Ash.Changeset.for_create(:create, %{title: "MaTcH"})
      |> Ash.create!()

      results =
        Post
        |> Ash.Query.filter(ilike(title, "%aTc%"))
        |> Ash.read!()

      assert [%Post{title: "MaTcH"}] = results

      results =
        Post
        |> Ash.Query.filter(ilike(title, "%atc%"))
        |> Ash.read!()

      assert [%Post{title: "MaTcH"}] = results
    end
  end

  describe "fragments" do
    test "double replacement works" do
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "match", score: 4})
        |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{title: "non_match", score: 2})
      |> Ash.create!()

      assert [%{title: "match"}] =
               Post
               |> Ash.Query.filter(fragment("? = ?", title, ^post.title))
               |> Ash.read!()

      assert [] =
               Post
               |> Ash.Query.filter(fragment("? = ?", title, "nope"))
               |> Ash.read!()
    end
  end

  describe "filtering on relationships that themselves have filters" do
    test "it doesn't raise an error" do
      Comment
      |> Ash.Query.filter(not is_nil(popular_ratings.id))
      |> Ash.read!()
    end

    test "it doesn't raise an error when nested" do
      Post
      |> Ash.Query.filter(not is_nil(comments.popular_ratings.id))
      |> Ash.read!()
    end
  end
end
