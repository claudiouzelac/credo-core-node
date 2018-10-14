defmodule CredoCoreNode.Pool do
  @moduledoc """
  The Pool context.
  """

  alias CredoCoreNode.Network
  alias CredoCoreNode.Pool.PendingTransaction
  alias Mnesia.Repo

  @doc """
  Returns the list of pending_transactions.
  """
  def list_pending_transactions() do
    Repo.list(PendingTransaction)
  end

  @doc """
  Gets a single pending_transaction.
  """
  def get_pending_transaction(hash) do
    Repo.get(PendingTransaction, hash)
  end

  @doc """
  Creates/updates a pending_transaction.
  """
  def write_pending_transaction(attrs) do
    Repo.write(PendingTransaction, attrs)
  end

  @doc """
  Deletes a pending_transaction.
  """
  def delete_pending_transaction(%PendingTransaction{} = pending_transaction) do
    Repo.delete(pending_transaction)
  end

  @doc """
  Generates a pending_transaction.
  """
  def generate_pending_transaction(private_key, attrs) do
    tx = struct(PendingTransaction, attrs)

    {:ok, sig, v} =
      tx
      |> PendingTransaction.hash(type: :unsigned_rlp)
      |> :libsecp256k1.ecdsa_sign_compact(private_key, :default, <<>>)

    sig = Base.encode16(sig)
    tx = Map.merge(tx, %{v: v, r: String.slice(sig, 0, 64), s: String.slice(sig, 64, 64)})

    {:ok, Map.put(tx, :hash, PendingTransaction.hash(tx, type: :signed_rlp, encoding: :hex))}
  end

  @doc """
  Propagates a pending_transaction.
  """
  def propagate_pending_transaction(tx) do
    # TODO: temporary REST implementation, to be replaced with channels-based one later
    headers = Network.node_request_headers()
    {:ok, body} = Poison.encode(%{hash: tx.hash, body: ExRLP.encode(tx, encoding: :hex)})

    Network.list_connections()
    |> Enum.filter(&(&1.is_active))
    |> Enum.map(&("#{Network.request_url(&1.ip)}/node_api/v1/temp/pending_transactions"))
    |> Enum.each(&(:hackney.request(:post, &1, headers, body, [:with_body, pool: false])))

    {:ok, tx}
  end

  @doc """
  Gets a batch of a pending_transaction.

  To be called when constructing a block.

  TODO: sort by transaction fee.
  """
  def get_batch_of_pending_transactions do
    list_pending_transactions()
    |> Enum.take(200)
  end
end