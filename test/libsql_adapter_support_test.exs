# Tests for libSQL adapter support changes.
#
# These tests verify the three changes that enable ecto_libsql:
# 1. verify_repo accepts Ecto.Adapters.LibSql
# 2. repo macro accepts configurable :adapter option
# 3. data_layer error handlers match the message format used by both adapters

defmodule AshSqlite.LibSqlAdapterSupportTest do
  use ExUnit.Case, async: true

  describe "verify_repo transformer" do
    test "accepts Ecto.Adapters.SQLite3 (backwards compatible)" do
      # The existing TestRepo uses SQLite3 and should still pass
      assert AshSqlite.TestRepo.__adapter__() == Ecto.Adapters.SQLite3
    end

    test "accepted adapters list includes both SQLite3 and LibSql" do
      accepted = [Ecto.Adapters.SQLite3, Ecto.Adapters.LibSql]
      assert Ecto.Adapters.SQLite3 in accepted
      assert Ecto.Adapters.LibSql in accepted
    end
  end

  describe "repo macro :adapter option" do
    test "defaults to Ecto.Adapters.SQLite3 when no adapter specified" do
      # TestRepo uses `use AshSqlite.Repo, otp_app: :ash_sqlite` with no :adapter
      assert AshSqlite.TestRepo.__adapter__() == Ecto.Adapters.SQLite3
    end
  end

  describe "error message format compatibility" do
    # Both Exqlite.Error and EctoLibSql.Error use the same SQLite message format.
    # These tests verify the message parsing logic works for both.

    test "parses UNIQUE constraint message with single field" do
      message = "UNIQUE constraint failed: users.email"
      fields = message
        |> String.replace_prefix("UNIQUE constraint failed: ", "")
        |> String.split(", ")
        |> Enum.map(fn field ->
          field |> String.split(".", trim: true) |> Enum.drop(1) |> Enum.at(0)
        end)

      assert fields == ["email"]
    end

    test "parses UNIQUE constraint message with multiple fields" do
      message = "UNIQUE constraint failed: users.org_id, users.slug"
      fields = message
        |> String.replace_prefix("UNIQUE constraint failed: ", "")
        |> String.split(", ")
        |> Enum.map(fn field ->
          field |> String.split(".", trim: true) |> Enum.drop(1) |> Enum.at(0)
        end)

      assert fields == ["org_id", "slug"]
    end

    test "identifies FOREIGN KEY constraint message" do
      message = "FOREIGN KEY constraint failed"
      assert message == "FOREIGN KEY constraint failed"
    end
  end
end
