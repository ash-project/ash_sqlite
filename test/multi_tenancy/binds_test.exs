# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.BindsTest do
  @moduledoc """
  A bound tenant is never evictable, and a closing tenant accepts no new binds.
  """
  use ExUnit.Case, async: true

  alias AshSqlite.MultiTenancy.Binds

  defmodule Repo do
    @moduledoc false
  end

  setup do
    start_supervised!(Binds.child_spec(Repo))
    :ok
  end

  describe "bound/2 and released/2" do
    test "count the processes using a tenant" do
      assert Binds.count(Repo, "acme") == 0

      assert :ok = Binds.bound(Repo, "acme")
      assert :ok = Binds.bound(Repo, "acme")
      assert Binds.count(Repo, "acme") == 2

      Binds.released(Repo, "acme")
      assert Binds.count(Repo, "acme") == 1
    end

    test "count tenants separately" do
      Binds.bound(Repo, "acme")

      assert Binds.count(Repo, "acme") == 1
      assert Binds.count(Repo, "globex") == 0
    end

    test "clamp at zero, so an unmatched release cannot make a busy tenant look idle" do
      Binds.released(Repo, "acme")
      Binds.released(Repo, "acme")
      assert Binds.count(Repo, "acme") == 0

      Binds.bound(Repo, "acme")
      assert Binds.count(Repo, "acme") == 1
    end

    test "releasing marks the tenant used" do
      refute Binds.last_used(Repo, "acme")

      Binds.bound(Repo, "acme")
      Binds.released(Repo, "acme")

      assert is_integer(Binds.last_used(Repo, "acme"))
    end
  end

  describe "closing" do
    test "refuses new binds while it is marked" do
      Binds.begin_closing(Repo, "acme")

      assert :closing = Binds.bound(Repo, "acme")
      assert Binds.count(Repo, "acme") == 0
    end

    test "accepts binds again once cleared" do
      Binds.begin_closing(Repo, "acme")
      Binds.end_closing(Repo, "acme")

      assert :ok = Binds.bound(Repo, "acme")
    end

    test "marks one tenant without affecting another" do
      Binds.begin_closing(Repo, "acme")

      assert Binds.closing?(Repo, "acme")
      refute Binds.closing?(Repo, "globex")
      assert :ok = Binds.bound(Repo, "globex")
    end

    test "is idempotent" do
      Binds.begin_closing(Repo, "acme")
      Binds.begin_closing(Repo, "acme")
      Binds.end_closing(Repo, "acme")

      refute Binds.closing?(Repo, "acme")
    end
  end

  describe "least_recently_used/2" do
    test "picks the tenant used longest ago, not the one started longest ago" do
      for tenant <- ["acme", "globex", "initech"] do
        Binds.bound(Repo, tenant)
        Binds.released(Repo, tenant)
      end

      # "acme" was started first but has just been used, so it must not be chosen.
      Binds.bound(Repo, "acme")
      Binds.released(Repo, "acme")

      assert Binds.least_recently_used(Repo, ["acme", "globex", "initech"]) == "globex"
    end

    test "never picks a tenant with work in flight" do
      Binds.bound(Repo, "acme")
      Binds.released(Repo, "acme")
      Binds.bound(Repo, "globex")
      Binds.released(Repo, "globex")

      # The least recently used tenant is now busy, so the next one must be chosen.
      Binds.bound(Repo, "acme")

      assert Binds.least_recently_used(Repo, ["acme", "globex"]) == "globex"
    end

    test "never picks a tenant that is already closing" do
      Binds.bound(Repo, "acme")
      Binds.released(Repo, "acme")
      Binds.bound(Repo, "globex")
      Binds.released(Repo, "globex")
      Binds.begin_closing(Repo, "acme")

      assert Binds.least_recently_used(Repo, ["acme", "globex"]) == "globex"
    end

    test "is nil when every candidate is in use, rather than choosing one anyway" do
      Binds.bound(Repo, "acme")
      Binds.bound(Repo, "globex")

      refute Binds.least_recently_used(Repo, ["acme", "globex"])
    end

    test "is nil for no candidates" do
      refute Binds.least_recently_used(Repo, [])
    end

    test "prefers a tenant never used over one used recently" do
      Binds.bound(Repo, "globex")
      Binds.released(Repo, "globex")

      assert Binds.least_recently_used(Repo, ["acme", "globex"]) == "acme"
    end
  end

  describe "forget/2" do
    test "drops everything recorded about a tenant" do
      Binds.bound(Repo, "acme")
      Binds.released(Repo, "acme")
      Binds.begin_closing(Repo, "acme")

      Binds.forget(Repo, "acme")

      assert Binds.count(Repo, "acme") == 0
      refute Binds.last_used(Repo, "acme")
      refute Binds.closing?(Repo, "acme")
    end

    test "leaves other tenants alone" do
      Binds.bound(Repo, "globex")
      Binds.forget(Repo, "acme")

      assert Binds.count(Repo, "globex") == 1
    end
  end
end
