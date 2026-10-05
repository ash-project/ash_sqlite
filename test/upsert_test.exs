# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.UpsertTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.Post

  import Ash.Expr
  require Ash.Query

  test "upserting results in the same created_at timestamp, but a new updated_at timestamp" do
    id = Ash.UUID.generate()

    new_post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id,
        title: "title2"
      })
      |> Ash.create!(upsert?: true)

    assert new_post.id == id
    assert new_post.created_at == new_post.updated_at

    updated_post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id,
        title: "title3"
      })
      |> Ash.create!(upsert?: true)

    assert updated_post.id == id
    assert updated_post.created_at == new_post.created_at
    assert updated_post.created_at != updated_post.updated_at
  end

  test "upserting a field with a default sets to the new value" do
    id = Ash.UUID.generate()

    new_post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id,
        title: "title2"
      })
      |> Ash.create!(upsert?: true)

    assert new_post.id == id
    assert new_post.created_at == new_post.updated_at

    updated_post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id,
        title: "title2",
        decimal: Decimal.new(5)
      })
      |> Ash.create!(upsert?: true)

    assert updated_post.id == id
    assert Decimal.equal?(updated_post.decimal, Decimal.new(5))
  end

  test "upsert with touch_update_defaults? false does not update updated_at" do
    id = Ash.UUID.generate()
    past = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second))

    Post
    |> Ash.Changeset.for_create(:create, %{
      id: id,
      title: "title"
    })
    |> Ash.create!()

    AshSqlite.TestRepo.query!("UPDATE posts SET updated_at = ? WHERE id = ?", [past, id])

    assert [%{updated_at: backdated}] = Ash.read!(Post)
    assert DateTime.compare(backdated, DateTime.from_iso8601(past) |> elem(1)) == :eq

    upserted =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id,
        title: "title2"
      })
      |> Ash.create!(upsert?: true, touch_update_defaults?: false)

    assert DateTime.compare(upserted.updated_at, DateTime.from_iso8601(past) |> elem(1)) == :eq
  end

  test "upsert with empty upsert_fields does not update updated_at" do
    id = Ash.UUID.generate()
    past = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second))

    Post
    |> Ash.Changeset.for_create(:create, %{
      id: id,
      title: "title"
    })
    |> Ash.create!()

    AshSqlite.TestRepo.query!("UPDATE posts SET updated_at = ? WHERE id = ?", [past, id])

    assert [%{updated_at: backdated}] = Ash.read!(Post)
    assert DateTime.compare(backdated, DateTime.from_iso8601(past) |> elem(1)) == :eq

    upserted =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id,
        title: "title2"
      })
      |> Ash.create!(upsert?: true, upsert_fields: [])

    assert DateTime.compare(upserted.updated_at, DateTime.from_iso8601(past) |> elem(1)) == :eq
  end

  describe "upsert_conflict/1 in an upsert_condition" do
    defp upsert_post(attrs, condition) do
      Post
      |> Ash.Changeset.for_create(:create, attrs,
        upsert?: true,
        upsert_fields: [:title, :score, :status_enum_no_cast],
        upsert_condition: condition
      )
      |> Ash.create!(return_skipped_upsert?: true)
    end

    defp create_post(attrs) do
      Post
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!()
    end

    test "updates the existing row when the condition holds" do
      id = Ash.UUID.generate()
      create_post(%{id: id, title: "title", score: 1})

      upserted =
        upsert_post(%{id: id, title: "title", score: 2}, expr(score < upsert_conflict(:score)))

      assert upserted.score == 2
    end

    test "skips the upsert when the condition does not hold" do
      id = Ash.UUID.generate()
      create_post(%{id: id, title: "title", score: 5})

      # `return_skipped_upsert?` returns the existing row, which was not written to
      skipped =
        upsert_post(%{id: id, title: "other", score: 2}, expr(score < upsert_conflict(:score)))

      assert skipped.id == id
      assert skipped.score == 5
      assert skipped.title == "title"
    end

    test "handles nil on either side of the comparison" do
      id = Ash.UUID.generate()
      create_post(%{id: id, title: "title"})

      condition =
        expr(
          score == upsert_conflict(:score) or
            (is_nil(score) and is_nil(upsert_conflict(:score)))
        )

      assert upsert_post(%{id: id, title: "other", score: 1}, condition).title == "title"
      assert upsert_post(%{id: id, title: "other"}, condition).title == "other"
    end

    test "resolves a field with a custom source column name" do
      id = Ash.UUID.generate()

      # `status_enum_no_cast` is stored in the `status_enum` column, so this only works if
      # `upsert_conflict/1` renders `EXCLUDED.status_enum` rather than `EXCLUDED.status_enum_no_cast`
      create_post(%{id: id, title: "title", status_enum_no_cast: :open})

      condition = expr(upsert_conflict(:status_enum_no_cast) == :closed)

      assert %{title: "title", status_enum_no_cast: :open} =
               upsert_post(%{id: id, title: "still open", status_enum_no_cast: :open}, condition)

      assert %{title: "now closed", status_enum_no_cast: :closed} =
               upsert_post(
                 %{id: id, title: "now closed", status_enum_no_cast: :closed},
                 condition
               )
    end
  end
end
