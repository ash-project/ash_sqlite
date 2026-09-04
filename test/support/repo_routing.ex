# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.RepoRouting do
  @moduledoc """
  A named function for a resource's `repo` to capture.

  A capture of a function on another module can be resolved while the resource is
  still compiling, so `write_transactions?` is read from the real repo. An inline
  `fn` cannot, and is refused.
  """
  def repo(_resource, :mutate), do: AshSqlite.TestRepo
  def repo(_resource, :read), do: AshSqlite.TestRepo
end
