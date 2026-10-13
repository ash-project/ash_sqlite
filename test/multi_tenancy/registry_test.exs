# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.RegistryTest do
  @moduledoc """
  Registration is the mutual exclusion, and a lookup must never hand out a dead process.
  """
  use ExUnit.Case, async: true

  alias AshSqlite.MultiTenancy.Registry, as: TenantRegistry

  defmodule Repo do
    @moduledoc false
  end

  setup do
    start_supervised!(TenantRegistry.child_spec(Repo))
    :ok
  end

  describe "via/2" do
    test "registers a process under the tenant" do
      connection = start_connection("acme")

      assert {:ok, ^connection, nil} = TenantRegistry.lookup(Repo, "acme")
    end

    test "refuses a second process for the same tenant, without running its init" do
      first = start_connection("acme")

      assert {:error, {:already_started, ^first}} =
               Agent.start(fn -> raise "init must not run" end,
                 name: TenantRegistry.via(Repo, "acme")
               )
    end

    test "keeps tenants that differ only by case apart" do
      lower = start_connection("acme")
      upper = start_connection("ACME")

      refute lower == upper
      assert {:ok, ^lower, _} = TenantRegistry.lookup(Repo, "acme")
      assert {:ok, ^upper, _} = TenantRegistry.lookup(Repo, "ACME")
    end
  end

  describe "publish/3" do
    test "makes the repo pid available to the next lookup" do
      connection = start_connection("acme")
      repo_pid = publish_self(connection, "acme")

      assert {:ok, ^connection, ^repo_pid} = TenantRegistry.lookup(Repo, "acme")
    end

    test "a connection that has not published yet is found, with no repo" do
      connection = start_connection("acme")

      assert {:ok, ^connection, nil} = TenantRegistry.lookup(Repo, "acme")
    end
  end

  describe "lookup/2" do
    test "is :error for a tenant with no connection" do
      assert :error = TenantRegistry.lookup(Repo, "nobody")
    end

    test "is :error for an entry whose process has died" do
      connection = start_connection("acme")
      publish_self(connection, "acme")

      ref = Process.monitor(connection)
      Process.exit(connection, :kill)
      assert_receive {:DOWN, ^ref, :process, ^connection, :killed}, 2_000

      # The entry may not have been reaped yet -- that is the point. A dead
      # connection must read as absent rather than as a pid to bind.
      assert :error = TenantRegistry.lookup(Repo, "acme")
    end
  end

  describe "resident/1 and count/1" do
    test "list the tenants with a connection" do
      start_connection("acme")
      start_connection("globex")

      assert Enum.sort(TenantRegistry.resident(Repo)) == ["acme", "globex"]
      assert TenantRegistry.count(Repo) == 2
    end

    test "are empty for a registry nobody has used" do
      assert TenantRegistry.resident(Repo) == []
      assert TenantRegistry.count(Repo) == 0
    end
  end

  describe "name/1" do
    test "is derived from the repo, so two repos do not share a namespace" do
      refute TenantRegistry.name(Repo) ==
               TenantRegistry.name(AshSqlite.MultiTenancy.BindsTest.Repo)
    end
  end

  defp start_connection(tenant) do
    {:ok, pid} = Agent.start(fn -> :ok end, name: TenantRegistry.via(Repo, tenant))
    pid
  end

  defp publish_self(connection, tenant) do
    Agent.get(connection, fn _ ->
      :ok = TenantRegistry.publish(Repo, tenant, self())
      self()
    end)
  end
end
