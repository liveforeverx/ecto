defmodule Ecto.Adapters.Mysql.Worker do
  @moduledoc false

  use GenServer.Behaviour

  defrecordp :state, [ :conn, :params, :monitor ]

  @timeout 5000

  def start(args) do
    :gen_server.start(__MODULE__, args, [])
  end

  def start_link(args) do
    :gen_server.start_link(__MODULE__, args, [])
  end

  def query!(worker, sql, params, timeout \\ @timeout) do
    case :gen_server.call(worker, { :query, sql, params, timeout }, timeout) do
      { :result_packet, _, _, rows, _  } ->
        EMysql.Result[rows: rows, num_rows: Enum.count(rows)]
      { :ok_packet, _seq_num, affected_rows, insert_id, _status, _warning_message, msg } ->
        EMysql.OkPacket[affected_rows: affected_rows, insert_id: insert_id, msg: msg]
      { :error_packet, _seq_num, _code, _, msg } ->
        EMysql.Error[msg: msg]
    end
  end

  def monitor_me(worker) do
    :gen_server.cast(worker, { :monitor, self })
  end

  def demonitor_me(worker) do
    :gen_server.cast(worker, { :demonitor, self })
  end

  def init(opts) do
    Process.flag(:trap_exit, true)

    lazy? = opts[:lazy] in [false, "false"]

    conn =

      # TODO mysql driver
      case lazy? and Postgrex.Connection.start_link(opts) do
        { :ok, conn } -> conn
        _ -> nil
      end

    { :ok, state(conn: conn, params: opts) }
  end

  # Connection is disconnected, reconnect before continuing
  def handle_call(request, from, state(conn: nil, params: params) = s) do
    pool_name = Keyword.get(params, :pool_name)
    params = translate_params(params)

    case :emysql.add_pool(pool_name, params) do
      :ok ->
        handle_call(request, from, state(s, conn: pool_name))
      { :error, :pool_already_exists } ->
        handle_call(request, from, state(s, conn: pool_name))
      { :error, err } ->
        { :reply, { :error, err }, s }
    end
  end

  def handle_call({ :query, sql, _params, _timeout }, _from, state(conn: conn) = s) do

    { :reply, :emysql.execute(conn, sql), s }
  end

  def handle_cast({ :monitor, pid }, state(monitor: nil) = s) do
    ref = Process.monitor(pid)
    { :noreply, state(s, monitor: { pid, ref }) }
  end

  def handle_cast({ :demonitor, pid }, state(monitor: { pid, ref }) = s) do
    Process.demonitor(ref)
    { :noreply, state(s, monitor: nil) }
  end

  def handle_info({ :EXIT, conn, _reason }, state(conn: conn) = s) do
    { :noreply, state(s, conn: nil) }
  end

  def handle_info({ :DOWN, ref, :process, pid, _info }, state(monitor: { pid, ref }) = s) do
    { :stop, :normal, s }
  end

  def handle_info(_info, s) do
    { :noreply, s }
  end

  def terminate(_reason, state(conn: nil)) do
    :ok
  end

  def terminate(_reason, state(conn: conn)) do
    :emysql.remove_pool(conn)
  end

  defp translate_params(params) do
    [
      size: 1,
      user: bitstring_to_list(params[:username]),
      password: bitstring_to_list(params[:password]),
      host: bitstring_to_list(params[:hostname]),
      port: params[:port],
      database: bitstring_to_list(params[:database]),
      encoding: :utf8
    ]
  end
end
