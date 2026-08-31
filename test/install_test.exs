# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.InstallTest do
  @moduledoc """
  The installer opts the generated repo into write transactions.

  Transactions are off by default in `AshSqlite.Repo`, so a new app only gets them
  because the installer writes the callback.
  """
  use ExUnit.Case

  import Igniter.Test

  test "a generated repo opts into write transactions" do
    test_project()
    |> Igniter.compose_task("ash_sqlite.install", [])
    |> assert_creates("lib/test/repo.ex")
    |> then(fn igniter ->
      assert igniter.rewrite
             |> Rewrite.source!("lib/test/repo.ex")
             |> Rewrite.Source.get(:content) =~ "def write_transactions?, do: true"

      igniter
    end)
  end

  test "an existing repo that already answers is left alone" do
    test_project(
      files: %{
        "lib/test/repo.ex" => """
        defmodule Test.Repo do
          use AshSqlite.Repo, otp_app: :test

          def write_transactions?, do: false
        end
        """
      }
    )
    |> Igniter.compose_task("ash_sqlite.install", [])
    |> then(fn igniter ->
      content =
        igniter.rewrite |> Rewrite.source!("lib/test/repo.ex") |> Rewrite.Source.get(:content)

      assert content =~ "def write_transactions?, do: false"
      refute content =~ "do: true"

      igniter
    end)
  end
end
