# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.SplitRepoRouting do
  @moduledoc """
  Named functions for a resource's `repo` to capture, for the tenant-repo tests.

  They cannot be inline `fn`s: a capture of a function on another module resolves
  while the resource is still compiling, and an inline `fn` is refused because it
  compiles into a function on the resource that is not loaded yet.
  """
  @doc "Different modules per usage -- what a binder cannot serve."
  def split(_resource, :read), do: AshSqlite.DevTestRepo
  def split(_resource, :mutate), do: AshSqlite.TestRepo

  @doc "One module for both usages -- accepted."
  def same(_resource, _type), do: AshSqlite.TestRepo
end
