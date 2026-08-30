# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.TenantRepoTest do
  @moduledoc """
  A `repo` function returning different modules for `:read` and `:mutate` cannot be
  served by a binder, because `put_dynamic_repo/1` binds one module at a time.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defp resource(name, body) do
    quote do
      defmodule unquote(name) do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: AshSqlite.DataLayer

        actions do
          defaults([:read])
        end

        attributes do
          uuid_primary_key(:id)
        end

        unquote(body)
      end
    end
  end

  # Raised from the resource's own verification, which is what fails `mix compile`.
  test "a split read/mutate repo is refused for a context-multitenant resource" do
    message =
      capture_io(:stderr, fn ->
        try do
          Code.eval_quoted(
            resource(
              SplitRepoPost,
              quote do
                multitenancy(do: strategy(:context))

                sqlite do
                  table("split_repo_posts")
                  migrate?(false)

                  repo(fn _resource, type ->
                    case type do
                      :read -> AshSqlite.DevTestRepo
                      :mutate -> AshSqlite.TestRepo
                    end
                  end)
                end
              end
            )
          )
        rescue
          _ -> :raised
        end
      end)

    assert message =~ "AshSqlite.DevTestRepo for :read"
    assert message =~ "AshSqlite.TestRepo for :mutate"
    assert message =~ "put_dynamic_repo"
    assert message =~ "tenant_binder"
  end

  test "a repo function returning one module for both is accepted" do
    Code.eval_quoted(
      resource(
        SameRepoPost,
        quote do
          multitenancy(do: strategy(:context))

          sqlite do
            table("same_repo_posts")
            migrate?(false)
            repo(fn _resource, _type -> AshSqlite.TestRepo end)
          end
        end
      )
    )

    assert AshSqlite.DataLayer.Info.repo(SameRepoPost, :read) == AshSqlite.TestRepo
    assert AshSqlite.DataLayer.Info.repo(SameRepoPost, :mutate) == AshSqlite.TestRepo
  end

  # The case the check would otherwise forbid: a binder of its own is told whether
  # each statement is a read or a write, so it can bind a replica for reads.
  test "a split is allowed when the resource names its own binder" do
    Code.eval_quoted(
      resource(
        SplitWithBinderPost,
        quote do
          multitenancy(do: strategy(:context))

          sqlite do
            table("split_with_binder_posts")
            migrate?(false)
            tenant_binder(AshSqlite.Test.TenantBinder)

            repo(fn _resource, type ->
              case type do
                :read -> AshSqlite.DevTestRepo
                :mutate -> AshSqlite.TestRepo
              end
            end)
          end
        end
      )
    )

    assert AshSqlite.DataLayer.Info.tenant_binder(SplitWithBinderPost) ==
             AshSqlite.Test.TenantBinder
  end

  # Nothing binds a resource with no context multitenancy, so a split is its own
  # business there and has been supported for as long as the `repo` option has.
  test "a split is allowed on a resource with no context multitenancy" do
    Code.eval_quoted(
      resource(
        SplitGlobalPost,
        quote do
          sqlite do
            table("split_global_posts")
            migrate?(false)

            repo(fn _resource, type ->
              case type do
                :read -> AshSqlite.DevTestRepo
                :mutate -> AshSqlite.TestRepo
              end
            end)
          end
        end
      )
    )

    assert AshSqlite.DataLayer.Info.repo(SplitGlobalPost, :read) == AshSqlite.DevTestRepo
  end
end
