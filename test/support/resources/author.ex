# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.Author do
  @moduledoc false
  use Ash.Resource,
    domain: AshSqlite.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("authors")
    repo(AshSqlite.TestRepo)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:first_name, :string, public?: true)
    attribute(:last_name, :string, public?: true)
    attribute(:bio, AshSqlite.Test.Bio, public?: true)
    attribute(:badges, {:array, :atom}, public?: true)
  end

  actions do
    default_accept(:*)
    defaults([:create, :read, :update, :destroy])
  end

  relationships do
    has_one(:profile, AshSqlite.Test.Profile, public?: true)
    has_many(:posts, AshSqlite.Test.Post, public?: true)
    has_many(:public_posts, AshSqlite.Test.Post, public?: true, read_action: :public)
  end

  aggregates do
    count(:count_of_comments_through_posts, [:posts, :comments])
    count(:count_of_comments_through_public_posts, [:public_posts, :comments])
    count(:count_of_linked_posts_through_posts, [:posts, :linked_posts])
    count(:total_profiles, AshSqlite.Test.Profile)
    sum(:total_post_score, AshSqlite.Test.Post, :score)
    avg(:avg_post_score, AshSqlite.Test.Post, :score)
    min(:min_post_score, AshSqlite.Test.Post, :score)
    max(:max_post_score, AshSqlite.Test.Post, :score)
    sum(:sum_of_comment_likes_through_posts, [:posts, :comments], :likes)
    avg(:avg_comment_likes_through_posts, [:posts, :comments], :likes)
    min(:min_comment_likes_through_posts, [:posts, :comments], :likes)
    max(:max_comment_likes_through_posts, [:posts, :comments], :likes)
    sum(:sum_of_linked_post_scores_through_posts, [:posts, :linked_posts], :score)
    avg(:avg_linked_post_score_through_posts, [:posts, :linked_posts], :score)
    min(:min_linked_post_score_through_posts, [:posts, :linked_posts], :score)
    max(:max_linked_post_score_through_posts, [:posts, :linked_posts], :score)

    count :count_of_comments_on_public_posts, [:posts, :comments] do
      join_filter(:posts, expr(public == true))
    end

    count :count_of_comments_called_match_with_join_filter, [:posts, :comments] do
      join_filter([:posts, :comments], expr(title == "match"))
    end

    exists :has_comment_called_match_through_posts, [:posts, :comments] do
      filter(expr(title == "match"))
    end

    exists :has_linked_post_called_match_through_posts, [:posts, :linked_posts] do
      filter(expr(title == "match"))
    end

    exists :has_any_profile, AshSqlite.Test.Profile do
      filter(expr(not is_nil(description)))
    end

    count :profiles_matching_first_name, AshSqlite.Test.Profile do
      filter(expr(description == parent(first_name)))
    end

    first :first_profile_description, AshSqlite.Test.Profile, :description do
      sort(description: :asc_nils_last)
    end

    list :profile_descriptions, AshSqlite.Test.Profile, :description do
      sort(description: :asc_nils_last)
    end

    list :comment_titles_through_posts, [:posts, :comments], :title do
      sort(title: :asc_nils_last)
    end

    list :linked_post_titles_through_posts, [:posts, :linked_posts], :title do
      sort(title: :asc_nils_last)
    end

    custom(:post_titles_joined, AshSqlite.Test.Post, :string) do
      implementation({AshSqlite.Test.StringAgg, field: :title, delimiter: ","})
    end

    custom(:comment_titles_joined_through_posts, [:posts, :comments], :string) do
      implementation({AshSqlite.Test.StringAgg, field: :title, delimiter: ","})
    end
  end

  calculations do
    calculate(:title, :string, expr(bio[:title]))
    calculate(:full_name, :string, expr(first_name <> " " <> last_name))
    # calculate(:full_name_with_nils, :string, expr(string_join([first_name, last_name], " ")))
    # calculate(:full_name_with_nils_no_joiner, :string, expr(string_join([first_name, last_name])))
    # calculate(:split_full_name, {:array, :string}, expr(string_split(full_name)))

    calculate(:first_name_or_bob, :string, expr(first_name || "bob"))
    calculate(:first_name_and_bob, :string, expr(first_name && "bob"))

    calculate(
      :conditional_full_name,
      :string,
      expr(
        if(
          is_nil(first_name) or is_nil(last_name),
          "(none)",
          first_name <> " " <> last_name
        )
      )
    )

    calculate(
      :nested_conditional,
      :string,
      expr(
        if(
          is_nil(first_name),
          "No First Name",
          if(
            is_nil(last_name),
            "No Last Name",
            first_name <> " " <> last_name
          )
        )
      )
    )

    calculate :param_full_name,
              :string,
              {AshSqlite.Test.Concat, keys: [:first_name, :last_name]} do
      argument(:separator, :string, default: " ", constraints: [allow_empty?: true, trim?: false])
    end

    calculate(:post_titles, {:array, :string}, expr(list(posts, field: :title)))

    calculate(
      :comment_likes_through_posts_plus_one,
      :integer,
      expr((sum_of_comment_likes_through_posts || 0) + 1)
    )

    calculate(
      :linked_post_score_through_posts_plus_one,
      :integer,
      expr((sum_of_linked_post_scores_through_posts || 0) + 1)
    )

    calculate(:total_profiles_plus_one, :integer, expr(total_profiles + 1))
  end
end
