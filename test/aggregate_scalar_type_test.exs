# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.AggregateScalarTypeTest do
  use AshSqlite.RepoCase, async: false

  alias AshSqlite.Test.{Comment, Post}

  defmodule Quantity do
    use Ash.Type

    defstruct [:value, :unit]

    @impl true
    def constraints, do: [unit: [type: :atom, default: :units]]

    @impl true
    def storage_type(_), do: :integer

    @impl true
    def cast_input(value, constraints), do: cast_stored(value, constraints)

    @impl true
    def cast_stored(nil, _), do: {:ok, nil}

    def cast_stored(value, constraints) when is_integer(value) do
      {:ok, %__MODULE__{value: value, unit: constraints[:unit]}}
    end

    def cast_stored(%__MODULE__{} = value, _), do: {:ok, value}
    def cast_stored(_, _), do: :error

    @impl true
    def dump_to_native(%__MODULE__{value: value}, _), do: {:ok, value}
    def dump_to_native(value, _) when is_integer(value) or is_nil(value), do: {:ok, value}
  end

  test "loaded scalar aggregates use their declared type and constraints" do
    post = Ash.Seed.seed!(%Post{title: "scalar types"})
    Ash.Seed.seed!(%Comment{post_id: post.id, likes: 3})
    Ash.Seed.seed!(%Comment{post_id: post.id, likes: 4})

    result =
      Post
      |> Ash.Query.aggregate(:total, :sum, :comments,
        field: :likes,
        type: Quantity,
        constraints: [unit: :points]
      )
      |> Ash.read_one!()

    assert result.aggregates.total == %Quantity{value: 7, unit: :points}
  end

  test "loaded scalar defaults use the same constrained type" do
    Ash.Seed.seed!(%Post{title: "empty scalar"})

    result =
      Post
      |> Ash.Query.aggregate(:total, :sum, :comments,
        field: :likes,
        default: 0,
        type: Quantity,
        constraints: [unit: :points]
      )
      |> Ash.read_one!()

    assert result.aggregates.total == %Quantity{value: 0, unit: :points}
  end
end
