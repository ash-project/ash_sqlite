# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.DatabaseTest do
  @moduledoc """
  A tenant becomes a filename, so this is where two tenants would come to share a database.
  """
  use ExUnit.Case, async: true

  alias AshSqlite.MultiTenancy.Database

  @seed 20_260_822

  describe "encode/1 and decode/1 round trip" do
    test "every single byte survives" do
      for byte <- 0..255 do
        tenant = <<byte>>
        assert {:ok, ^tenant} = Database.decode(Database.encode(tenant))
      end
    end

    test "tenants people actually use survive" do
      for tenant <- corpus() do
        assert {:ok, ^tenant} = Database.decode(Database.encode(tenant)),
               "did not round trip: #{inspect(tenant)}"
      end
    end

    test "generated tenants survive, and no two of them collide" do
      tenants = generated_tenants()

      for tenant <- tenants do
        assert {:ok, ^tenant} = Database.decode(Database.encode(tenant)),
               "did not round trip: #{inspect(tenant)} (seed #{@seed})"
      end

      encoded = Enum.map(tenants, &Database.encode/1)

      assert Enum.count(Enum.uniq(encoded)) == Enum.count(Enum.uniq(tenants)),
             "two distinct tenants encoded to one name (seed #{@seed})"
    end
  end

  describe "collisions the obvious implementation would allow" do
    test "punctuation is not flattened into the character that replaces it" do
      refute Database.encode("a:b") == Database.encode("a_b")
      refute Database.encode("a/b") == Database.encode("a_b")
      refute Database.encode("a b") == Database.encode("a-b")
    end

    test "an escape in the tenant does not alias an escape we produced" do
      refute Database.encode("~3a") == Database.encode(":")
    end

    test "encodings never differ only by case, so a case-insensitive filesystem is safe" do
      for tenant <- corpus() ++ generated_tenants() do
        encoded = Database.encode(tenant)

        assert String.downcase(encoded) == encoded,
               "#{inspect(tenant)} encoded to #{inspect(encoded)}, which has case (seed #{@seed})"
      end
    end

    test "tenants differing only by case get different files" do
      refute Database.encode("Acme") == Database.encode("acme")
      assert Database.encode("Acme") == "~41cme"
    end
  end

  describe "encode/1 keeps the name inside the directory" do
    test "no encoded name contains a path separator or a null" do
      for tenant <- ["../../etc/passwd", "a/b", "a\\b", "..", ".", "/", <<0>>] do
        encoded = Database.encode(tenant)
        refute String.contains?(encoded, ["/", "\\", <<0>>])
      end
    end

    test "a traversing tenant stays a single file in dir" do
      path = Database.path("/tmp/tenants", "../../etc/passwd")

      assert path == "/tmp/tenants/..~2f..~2fetc~2fpasswd.db"
      assert Path.dirname(Path.expand(path)) == "/tmp/tenants"
    end

    test "dot-only tenants are ordinary filenames" do
      assert Path.dirname(Path.expand(Database.path("/tmp/tenants", "."))) == "/tmp/tenants"
      assert Path.dirname(Path.expand(Database.path("/tmp/tenants", ".."))) == "/tmp/tenants"
    end
  end

  describe "encode/1 refuses what it cannot name" do
    test "a non-binary tenant, rather than stringifying it into a collision" do
      assert_raise ArgumentError, ~r/expected a binary tenant/, fn -> Database.encode(:acme) end
      assert_raise ArgumentError, ~r/expected a binary tenant/, fn -> Database.encode(1) end
      assert_raise ArgumentError, ~r/expected a binary tenant/, fn -> Database.encode(nil) end
    end

    test "an empty tenant" do
      assert_raise ArgumentError, ~r/cannot be an empty string/, fn -> Database.encode("") end
    end

    test "a tenant too long to be a filename, before the filesystem does" do
      assert_raise ArgumentError, ~r/encodes to \d+ bytes/, fn ->
        Database.encode(String.duplicate("a", 249))
      end

      # Escaped bytes cost three each, so the limit arrives three times sooner.
      assert_raise ArgumentError, ~r/encodes to \d+ bytes/, fn ->
        Database.encode(String.duplicate(":", 83))
      end
    end

    test "the longest name that does fit is accepted" do
      assert byte_size(Database.encode(String.duplicate("a", 248))) == 248
    end
  end

  describe "decode/1 declines what encode/1 could not have produced" do
    test "an unterminated or malformed escape" do
      assert :error = Database.decode("acme~")
      assert :error = Database.decode("acme~3")
      assert :error = Database.decode("acme~zz")
      assert :error = Database.decode("acme~3z")
    end

    test "uppercase hex, which we never emit" do
      assert :error = Database.decode("acme~3A")
    end

    test "a byte that would have been escaped, appearing raw" do
      assert :error = Database.decode("acme:2026")
      assert :error = Database.decode("Acme")
      assert :error = Database.decode("acme name")
    end

    test "an empty name" do
      assert :error = Database.decode("")
    end
  end

  describe "sidecars/1" do
    test "names the WAL and shared-memory files alongside the database" do
      assert Database.sidecars("/tmp/t/acme.db") == [
               "/tmp/t/acme.db",
               "/tmp/t/acme.db-wal",
               "/tmp/t/acme.db-shm"
             ]
    end
  end

  describe "tenant_from_path/2" do
    test "recovers the tenant of a database in the directory" do
      path = Database.path("/tmp/tenants", "acme:2026-08")
      assert {:ok, "acme:2026-08"} = Database.tenant_from_path("/tmp/tenants", path)
    end

    test "declines a path outside the directory" do
      assert :error = Database.tenant_from_path("/tmp/tenants", "/tmp/other/acme.db")
    end

    test "declines a path nested below the directory" do
      assert :error = Database.tenant_from_path("/tmp/tenants", "/tmp/tenants/sub/acme.db")
    end

    test "declines a file that is not a database" do
      assert :error = Database.tenant_from_path("/tmp/tenants", "/tmp/tenants/acme.sqlite")
    end

    test "declines a name no tenant could have produced" do
      assert :error = Database.tenant_from_path("/tmp/tenants", "/tmp/tenants/Backup.db")
    end
  end

  defp corpus do
    [
      "acme",
      "acme-corp",
      "acme_corp",
      "acme.corp",
      "ACME",
      "Acme",
      "acme:2026-08",
      "acme:billing",
      "0191f3d0-4d1e-7c3a-9c9e-1b2c3d4e5f60",
      "0191F3D0-4D1E-7C3A-9C9E-1B2C3D4E5F60",
      "tenant 42",
      "~",
      "~3a",
      "..",
      ".",
      "/",
      "../../etc/passwd",
      "日本語",
      "emoji-🙂",
      <<0>>,
      <<255, 254, 253>>,
      "a\nb",
      "'; drop table users; --"
    ]
  end

  # Includes invalid UTF-8: a tenant is whatever the application put in `set_tenant/2`.
  defp generated_tenants do
    :rand.seed(:exsss, {@seed, @seed, @seed})

    for _ <- 1..2_000 do
      length = :rand.uniform(24)
      for _ <- 1..length, into: <<>>, do: <<:rand.uniform(256) - 1>>
    end
    |> Enum.uniq()
  end
end
