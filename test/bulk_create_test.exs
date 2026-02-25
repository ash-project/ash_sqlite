# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.BulkCreateTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.Post

  describe "bulk creates" do
    test "bulk creates insert each input" do
      Ash.bulk_create!([%{title: "fred"}, %{title: "george"}], Post, :create)

      assert [%{title: "fred"}, %{title: "george"}] =
               Post
               |> Ash.Query.sort(:title)
               |> Ash.read!()
    end

    test "bulk creates can be streamed" do
      assert [{:ok, %{title: "fred"}}, {:ok, %{title: "george"}}] =
               Ash.bulk_create!([%{title: "fred"}, %{title: "george"}], Post, :create,
                 return_stream?: true,
                 return_records?: true
               )
               |> Enum.sort_by(fn {:ok, result} -> result.title end)
    end

    test "bulk creates can upsert" do
      assert [
               {:ok, %{title: "fred", uniq_one: "one", uniq_two: "two", price: 10}},
               {:ok, %{title: "george", uniq_one: "three", uniq_two: "four", price: 20}}
             ] =
               Ash.bulk_create!(
                 [
                   %{title: "fred", uniq_one: "one", uniq_two: "two", price: 10},
                   %{title: "george", uniq_one: "three", uniq_two: "four", price: 20}
                 ],
                 Post,
                 :create,
                 return_stream?: true,
                 return_records?: true
               )
               |> Enum.sort_by(fn {:ok, result} -> result.title end)

      assert [
               {:ok, %{title: "fred", uniq_one: "one", uniq_two: "two", price: 1000}},
               {:ok, %{title: "george", uniq_one: "three", uniq_two: "four", price: 20_000}}
             ] =
               Ash.bulk_create!(
                 [
                   %{title: "something", uniq_one: "one", uniq_two: "two", price: 1000},
                   %{title: "else", uniq_one: "three", uniq_two: "four", price: 20_000}
                 ],
                 Post,
                 :create,
                 upsert?: true,
                 upsert_identity: :uniq_one_and_two,
                 upsert_fields: [:price],
                 return_stream?: true,
                 return_records?: true
               )
               |> Enum.sort_by(fn
                 {:ok, result} ->
                   result.title

                 _ ->
                   nil
               end)
    end

    test "bulk creates with upsert updates update_timestamp" do
      past = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second))

      assert [{:ok, %{title: "fred", uniq_one: "one", uniq_two: "two"} = initial}] =
               Ash.bulk_create!(
                 [%{title: "fred", uniq_one: "one", uniq_two: "two", price: 10}],
                 Post,
                 :create,
                 return_stream?: true,
                 return_records?: true
               )
               |> Enum.to_list()

      # Backdate updated_at via raw SQL so the upsert has something to compare against
      AshSqlite.TestRepo.query!("UPDATE posts SET updated_at = ? WHERE id = ?", [
        past,
        initial.id
      ])

      assert [%{updated_at: backdated}] = Ash.read!(Post)
      assert DateTime.compare(backdated, DateTime.from_iso8601(past) |> elem(1)) == :eq

      assert [{:ok, %{title: "fred", price: 1000} = upserted}] =
               Ash.bulk_create!(
                 [%{title: "something", uniq_one: "one", uniq_two: "two", price: 1000}],
                 Post,
                 :create,
                 upsert?: true,
                 upsert_identity: :uniq_one_and_two,
                 upsert_fields: [:price],
                 return_stream?: true,
                 return_errors?: true,
                 return_records?: true
               )
               |> Enum.to_list()

      assert DateTime.after?(upserted.updated_at, DateTime.from_iso8601(past) |> elem(1))
    end

    test "bulk creates with empty upsert does not update update_timestamp" do
      past = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second))

      assert [{:ok, %{title: "fred", uniq_one: "one", uniq_two: "two"} = initial}] =
               Ash.bulk_create!(
                 [%{title: "fred", uniq_one: "one", uniq_two: "two", price: 10}],
                 Post,
                 :create,
                 return_stream?: true,
                 return_records?: true
               )
               |> Enum.to_list()

      AshSqlite.TestRepo.query!("UPDATE posts SET updated_at = ? WHERE id = ?", [
        past,
        initial.id
      ])

      assert [%{updated_at: backdated}] = Ash.read!(Post)
      assert DateTime.compare(backdated, DateTime.from_iso8601(past) |> elem(1)) == :eq

      assert [{:ok, %{title: "fred"} = upserted}] =
               Ash.bulk_create!(
                 [%{title: "something", uniq_one: "one", uniq_two: "two", price: 1000}],
                 Post,
                 :create,
                 upsert?: true,
                 upsert_identity: :uniq_one_and_two,
                 upsert_fields: [],
                 return_stream?: true,
                 return_errors?: true,
                 return_records?: true
               )
               |> Enum.to_list()

      assert DateTime.compare(upserted.updated_at, DateTime.from_iso8601(past) |> elem(1)) == :eq
    end

    test "bulk creates with upsert does not update update_timestamp when touch_update_defaults? is false" do
      past = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second))

      assert [{:ok, %{title: "fred", uniq_one: "one", uniq_two: "two"} = initial}] =
               Ash.bulk_create!(
                 [%{title: "fred", uniq_one: "one", uniq_two: "two", price: 10}],
                 Post,
                 :create,
                 return_stream?: true,
                 return_records?: true
               )
               |> Enum.to_list()

      AshSqlite.TestRepo.query!("UPDATE posts SET updated_at = ? WHERE id = ?", [
        past,
        initial.id
      ])

      assert [%{updated_at: backdated}] = Ash.read!(Post)
      assert DateTime.compare(backdated, DateTime.from_iso8601(past) |> elem(1)) == :eq

      assert [{:ok, %{title: "fred", price: 1000} = upserted}] =
               Ash.bulk_create!(
                 [%{title: "something", uniq_one: "one", uniq_two: "two", price: 1000}],
                 Post,
                 :create,
                 upsert?: true,
                 upsert_identity: :uniq_one_and_two,
                 upsert_fields: [:price],
                 context: %{data_layer: %{touch_update_defaults?: false}},
                 return_stream?: true,
                 return_errors?: true,
                 return_records?: true
               )
               |> Enum.to_list()

      assert DateTime.compare(upserted.updated_at, DateTime.from_iso8601(past) |> elem(1)) == :eq
    end

    test "bulk creates can create relationships" do
      Ash.bulk_create!(
        [%{title: "fred", rating: %{score: 5}}, %{title: "george", rating: %{score: 0}}],
        Post,
        :create
      )

      assert [
               %{title: "fred", ratings: [%{score: 5}]},
               %{title: "george", ratings: [%{score: 0}]}
             ] =
               Post
               |> Ash.Query.sort(:title)
               |> Ash.Query.load(:ratings)
               |> Ash.read!()
    end
  end

  describe "validation errors" do
    test "skips invalid by default" do
      assert %{records: [_], errors: [_]} =
               Ash.bulk_create([%{title: "fred"}, %{title: "not allowed"}], Post, :create,
                 return_records?: true,
                 return_errors?: true
               )
    end

    test "returns errors in the stream" do
      assert [{:ok, _}, {:error, _}] =
               Ash.bulk_create!([%{title: "fred"}, %{title: "not allowed"}], Post, :create,
                 return_records?: true,
                 return_stream?: true,
                 return_errors?: true
               )
               |> Enum.to_list()
    end
  end

  describe "database errors" do
    test "database errors affect the entire batch" do
      org =
        AshSqlite.Test.Organization
        |> Ash.Changeset.for_create(:create, %{name: "foo"})
        |> Ash.create!()

      Ash.bulk_create(
        [
          %{title: "fred", organization_id: org.id},
          %{title: "george", organization_id: Ash.UUID.generate()}
        ],
        Post,
        :create,
        return_records?: true
      )

      assert [] =
               Post
               |> Ash.Query.sort(:title)
               |> Ash.read!()
    end

    test "database errors don't affect other batches" do
      Ash.bulk_create(
        [%{title: "george", organization_id: Ash.UUID.generate()}, %{title: "fred"}],
        Post,
        :create,
        return_records?: true,
        batch_size: 1
      )

      assert [%{title: "fred"}] =
               Post
               |> Ash.Query.sort(:title)
               |> Ash.read!()
    end
  end
end
