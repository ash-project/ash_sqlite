defmodule AshSqlite.EnumTest do
  @moduledoc false
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Api, Post}

  require Ash.Query

  test "valid values are properly inserted" do
    Post
    |> Ash.Changeset.new(%{title: "title", status: :open})
    |> Api.create!()
  end
end
