# Transactions and SQLite

By default SQLite3 allows only one write transaction to be running at a time. Any attempt to commit a transaction while another is running will result in an error.  Because Elixir is a highly concurrent environment and [Ecto](https://hexdocs.pm/ecto) uses a connection pool by default, AshSqlite disables transactions by default.  This can lead to some surprising behaviours if you're used to working with AshPostgres - for example after action hooks which fail will leave records behind, but the action which ran them will return an error.  This document discusses some strategies for working around this constraint.

## Replacing transactions with Reactor sagas

A saga is a way of making transaction-like behaviour by explicitly telling the system to undo any changes it has made up until the point of failure.  This works well for remote resources such as web APIs, but also for working with Ash data layers that do not support transactions.  As a general rule; anything you could model with action lifecycle hooks can also be modelled with Reactor, with the addition of a bit more ceremony.

For our example, we'll use the idea of a system where posting a comment needs to increment an engagement score.  Here's how you could naively implement it:

```elixir
defmodule MyApp.Blog.Comment do
  use Ash.Resource,
    data_layer: AshSqlite.DataLayer,
    domain: MyApp.Blog
    
  attributes do
    uuid_primary_key :id
    
    attribute :body, :string, allow_nil?: false, public?: true
    
    create_timestamp :inserted_at
  end
  
  
  actions do
    defaults [:read, :destroy, update: :*]
    
    create :create do
      argument :post_id, :uuid, allow_nil?: false, public?: true
      
      primary? true
      
      change manage_relationsip(:post_id, :post, type: :append)
      change relate_to_actor(:author)
      
      change after_action(fn _changeset, record, context ->
        context.actor
        |> Ash.Changeset.for_update(:increment_engagement)
        |> Ash.update(actor: context.actor)
        |> case do
          {:ok, _} -> {:ok, record}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end
  
  relationships do
    belongs_to :author, MyApp.Blog.User, public?: true, writable?: true
    belongs_to :post, MyApp.Blog.Post, public?: true, writable?: true
  end
end

defmodule MyApp.Blog.User do
  use Ash.Resource,
    data_layer: AshSqlite.DataLayer,
    domain: MyApp.Blog
    
  attributes do
    uuid_primary_key :id
    
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :engagement_level, :integer, allow_nil?: false, default: 0, public?: true
    
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
  
  actions do
    defaults [:read, :destroy, create: :*, update: :*]
    
    update :increment_engagement do
      public? true
      change increment(:engagement_level, amount: 1)
    end
    
    update :decrement_engagement do
      public? true
      change increment(:engagement_level, amount: -1)
    end
  end
  
  relationships do
    has_many :posts, MyApp.Blog.Post, public?: true, destination_attribute: :author_id
    has_many :comments, MyApp.Blog.Comment, public?: true, destination_attribute: :author_id
  end
end
```

This would work as expected - as long as everything goes according to plan - if, however, there is a transient failure, or some kind of validation error in one of the hooks could cause the comment to be created, but the create action to still return an error.

Converting the create into a Reactor requires us to be explicit about how our steps are composed and what the dependencies between them are:

```elixir
defmodule MyApp.Blog.Comment do
  # ...
  
  actions do
    defaults [:read, :destroy, update: :*, create: :*]
    
    action :post_comment, :struct do
      constraints instance_of: __MODULE__
      argument :body, :string, allow_nil?: false, public?: true
      argument :post_id, :uuid, allow_nil?: false, public?: true
      argument :author_id, :uuid, allow_nil?: false, public?: true
      run MyApp.Blog.PostCommentReactor
    end
  end
  
  # ...
end

defmodule MyApp.Blog.PostCommentReactor do
  use Reactor, extensions: [Ash.Reactor]
  
  input :body
  input :post_id
  input :author_id
  
  read_one :get_author, MyApp.Blog.User, :get_by_id do
    inputs %{id: input(:author_id)}
    fail_on_not_found? true
    authorize? false
  end
  
  create :create_comment, MyApp.Blog.Comment, :create do
    inputs %{
      body: input(:body),
      post_id: input(:post_id),
      author_id: input(:author_id)
    }
    
    actor result(:get_author)
    undo :always
    undo_action :destroy
  end
  
  update :update_author_engagement, MyApp.Blog.User, :increment_engagement do
    initial result(:get_author)
    actor result(:get_author)
    undo :always
    undo_action :decrement_engagement
  end
  
  return :create_comment
end
```

> {: .neutral}
> Note that the examples above are edited for brevity and will not run with without modification

## Enabling transactions

Sometimes you really just want to be able to use a database transaction, in which case you can set `enable_write_transactions?` to `true` in the `sqlite` DSL block:

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    data_layer: AshSqlite.DataLayer,
    domain: MyApp.Blog
    
  sqlite do
    repo MyApp.Repo
    enable_write_transactions? true
  end
end
```

This will allow you to set `transaction? true` on actions. Doing this needs very careful management to ensure that all transactions are serialised.

Strategies for serialising transactions include:

 - Running all writes through a single `GenServer`.
 - Using a separate write repo with a pool size of 1.