defmodule AshSqlite.TransactionTest do
  @moduledoc false
  use AshSqlite.RepoCase, async: false

  describe "transactions are allowed when enabled" do
    @describetag repo: AshSqlite.TransactingRepo

    alias AshSqlite.Test.TransactingPost, as: Post

    test "manual transaction" do
      post_id = Ash.UUID.generate()

      Ash.transaction(Post, fn ->
        Post
        |> Ash.create!(
          %{
            id: post_id,
            title: "George McFly Murdered",
            subtitle: "Local Author Shot Dead"
          },
          transaction?: true
        )
      end)

      Ash.get!(Post, post_id)
    end
  end

  describe "transactions are disallowed when disabled" do
    @describetag repo: AshSqlite.TestRepo
    alias AshSqlite.Test.Post

    test "manual transaction" do
      post_id = Ash.UUID.generate()

      Ash.transaction(Post, fn ->
        Post
        |> Ash.create!(
          %{
            id: post_id,
            title: "George McFly Murdered"
          },
          transaction?: true
        )
      end)

      Ash.get!(Post, post_id)
    end
  end
end
