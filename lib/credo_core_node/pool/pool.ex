defmodule CredoCoreNode.Pool do
  @moduledoc """
  The Pool context.
  """

  alias CredoCoreNode.{Accounts, Blockchain, Network}
  alias CredoCoreNode.Pool.{PendingBlock, PendingTransaction}
  alias MerklePatriciaTree.Trie

  alias Decimal, as: D

  @doc """
  Returns the list of pending_transactions.
  """
  def list_pending_transactions() do
    Mnesia.Repo.list(PendingTransaction)
  end

  def list_pending_transactions(block) do
    MPT.Repo.list(block.tx_trie, PendingTransaction)
  end

  @doc """
  Gets a single pending_transaction.
  """
  def get_pending_transaction(hash) do
    Mnesia.Repo.get(PendingTransaction, hash)
  end

  @doc """
  Gets the sum of pending transaction fees.
  """
  def sum_pending_transaction_fees(txs) do
    fees = for %{fee: fee} <- txs, do: D.new(fee)
    Enum.reduce(fees, fn x, acc -> D.add(x, acc) end)
  end

  @doc """
  Creates/updates a pending_transaction.
  """
  def write_pending_transaction(attrs) do
    Mnesia.Repo.write(PendingTransaction, attrs)
  end

  @doc """
  Deletes a pending_transaction.
  """
  def delete_pending_transaction(%PendingTransaction{} = pending_transaction) do
    Mnesia.Repo.delete(pending_transaction)
  end

  @doc """
  Generates a pending_transaction.
  """
  def generate_pending_transaction(private_key, attrs) do
    tx = struct(PendingTransaction, attrs)

    tx = sign_message(private_key, tx)

    {:ok, %{tx | hash: RLP.Hash.hex(tx)}}
  end

  def sign_message(private_key, message) do
    {:ok, sig, v} =
      message
      |> RLP.Hash.binary(type: :unsigned)
      |> :libsecp256k1.ecdsa_sign_compact(private_key, :default, <<>>)

    sig = Base.encode16(sig)
    Map.merge(message, %{v: v, r: String.slice(sig, 0, 64), s: String.slice(sig, 64, 64)})
  end

  @doc """
  Propagates a pending_transaction.
  """
  def propagate_pending_transaction(tx) do
    Network.propagate_record(tx)

    {:ok, tx}
  end

  @doc """
  Gets a batch of a pending_transaction.

  To be called when constructing a block.
  """
  def get_batch_of_pending_transactions do
    list_pending_transactions()
    |> Enum.sort(&(&1.fee > &2.fee))
    |> Enum.take(200)
  end

  @doc """
  Returns the list of pending_blocks.
  """
  def list_pending_blocks() do
    Mnesia.Repo.list(PendingBlock)
  end

  @doc """
  Returns the list of pending_blocks for a given block number.
  """
  def list_pending_blocks(number) do
    list_pending_blocks()
    |> Enum.filter(&(&1.number == number))
  end

  @doc """
  Gets a single pending_block.
  """
  def get_pending_block(hash) do
    Mnesia.Repo.get(PendingBlock, hash)
  end

  def get_block_by_number(number) do
    list_pending_blocks(number)
    |> List.first()
  end

  def load_pending_block_body(nil), do: nil
  def load_pending_block_body(%PendingBlock{hash: nil} = pending_block), do: pending_block

  def load_pending_block_body(%PendingBlock{} = pending_block) do
    db = MerklePatriciaTree.DB.LevelDB.init("./leveldb/pending_blocks/#{pending_block.hash}")

    if db |> elem(1) |> Exleveldb.is_empty?() do
      pending_block
    else
      body =
        db
        |> Trie.new(elem(Base.decode16(pending_block.tx_root), 1))
        |> MPT.Repo.list(PendingTransaction)
        |> ExRLP.encode()

      %{pending_block | body: body}
    end
  end

  @doc """
  Creates/updates a pending_block.
  """
  def write_pending_block(%PendingBlock{hash: hash, body: body} = pending_block)
      when not is_nil(hash) and not is_nil(body) do
    pending_transactions =
      body
      |> ExRLP.decode()
      |> Enum.map(&PendingTransaction.from_list(&1, type: :rlp_default))

    {:ok, _tx_trie, _pending_transactions} =
      "./leveldb/pending_blocks/#{hash}"
      |> MerklePatriciaTree.DB.LevelDB.init()
      |> Trie.new()
      |> MPT.Repo.write_list(PendingTransaction, pending_transactions)

    pending_block
    |> Map.drop([:tx_trie, :body])
    |> write_pending_block()
  end

  @doc """
  Creates/updates a pending_block.
  """
  def write_pending_block(%PendingBlock{hash: hash, tx_trie: tx_trie} = pending_block)
      when not is_nil(hash) and not is_nil(tx_trie) do
    tx_trie
    |> Map.put(:db, MerklePatriciaTree.DB.LevelDB.init("./leveldb/pending_blocks/#{hash}"))
    |> Trie.store()

    pending_block
    |> Map.drop([:tx_trie, :body])
    |> write_pending_block()
  end

  @doc """
  Creates/updates a pending_block.
  """
  def write_pending_block(attrs) do
    Mnesia.Repo.write(PendingBlock, attrs)
  end

  @doc """
  Deletes a pending_block.
  """
  def delete_pending_block(%PendingBlock{} = pending_block) do
    Mnesia.Repo.delete(pending_block)
  end

  @doc """
  Generates a pending_block.
  """
  def generate_pending_block(pending_transactions) when pending_transactions == [],
    do: {:error, :no_txs}

  def generate_pending_block(pending_transactions) do
    last_block =
      Blockchain.list_blocks()
      |> Enum.sort(&(&1.number > &2.number))
      |> List.first()

    {number, prev_hash} =
      if last_block, do: {last_block.number + 1, last_block.hash}, else: {0, ""}

    # Temporary in-memory storage
    {:ok, tx_trie, _pending_transactions} =
      MerklePatriciaTree.DB.ETS.random_ets_db()
      |> Trie.new()
      |> MPT.Repo.write_list(PendingTransaction, pending_transactions)

    tx_root = Base.encode16(tx_trie.root_hash)

    pending_block = %PendingBlock{
      prev_hash: prev_hash,
      number: number,
      state_root: "",
      receipt_root: "",
      tx_root: tx_root,
      body: nil
    }

    {:ok, %PendingBlock{pending_block | hash: RLP.Hash.hex(pending_block), tx_trie: tx_trie}}
  end

  def fetch_pending_block_body(block, ip) do
    url = "#{Network.api_url(ip)}/pending_block_bodies/#{block.hash}"
    headers = Network.node_request_headers(:rlp)

    case :hackney.request(:get, url, headers, "", [:with_body, pool: false]) do
      {:ok, 200, _headers, body} -> write_pending_block(%{block | body: body})
      {:ok, 204, _headers, _body} -> {:error, :no_content}
      {:ok, 404, _headers, _body} -> {:error, :not_found}
      _ -> {:error, :unknown}
    end
  end

  def propagate_pending_block(block) do
    Network.propagate_record(block, recipients: :miners)

    {:ok, block}
  end

  def get_transaction_from_address(tx) do
    tx
    |> Accounts.calculate_public_key()
    |> elem(1)
    |> Accounts.payment_address()
  end

  def is_tx_from_balance_sufficient?(tx) do
    tx
    |> get_transaction_from_address()
    |> Accounts.get_account_balance()
    |> D.cmp(D.new(tx.value)) == :gt
  end

  def is_tx_invalid?(tx) do
    !is_tx_from_balance_sufficient?(tx)
  end
end
