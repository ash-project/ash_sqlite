# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.StringTrimTest do
  @moduledoc false

  use AshSqlite.RepoCase, async: false

  alias AshSqlite.Test.Post
  require Ash.Query

  test "string_trim can be used in filters to normalize whitespace" do
    Post
    |> Ash.Changeset.for_create(:create, %{title: "match"})
    |> Ash.create!()

    # A direct equality filter on the untrimmed value should not match when comparing to the trimmed string
    assert [] ==
             Post
             |> Ash.Query.filter(title == "  match  ")
             |> Ash.read!()

    # Using string_trim in the filter should match the record
    assert [%Post{title: "match"}] =
             Post
             |> Ash.Query.filter(title == string_trim("  match  "))
             |> Ash.read!()
  end
end
