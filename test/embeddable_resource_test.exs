defmodule AshSqlite.EmbeddableResourceTest do
  @moduledoc false
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Api, Author, Bio, Post}

  require Ash.Query

  setup do
    post =
      Post
      |> Ash.Changeset.new(%{title: "title"})
      |> Api.create!()

    %{post: post}
  end

  test "calculations can load json", %{post: post} do
    assert %{calc_returning_json: %AshSqlite.Test.Money{amount: 100, currency: :usd}} =
             Api.load!(post, :calc_returning_json)
  end

  test "embeds with list attributes set to nil are loaded as nil" do
    post =
      Author
      |> Ash.Changeset.new(%{bio: %Bio{list_of_strings: nil}})
      |> Api.create!()

    assert is_nil(post.bio.list_of_strings)

    post = Api.reload!(post)

    assert is_nil(post.bio.list_of_strings)
  end
end
