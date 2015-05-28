defmodule Durga.Client do
  defstruct reqs: %{},
            handlers: %{}

  require Logger
  alias Durga.Transport

  def start_link(name, url, size, opts \\ []) do
    agent = Agent.start_link(fn -> %{} end, name: Module.concat(__MODULE__, name))
    PoolRing.start(name, size, fn(_i, _) ->
      registered = Agent.get(Module.concat(__MODULE__, name), &(&1))
      :websocket_client.start_link(url, __MODULE__, [{:registered, registered} | opts])
    end)
    agent
  end

  def register(name, module, function, arity, handler, env \\ "prod") do
    for pid <- PoolRing.list(name) do
      send(pid, {:register, module, function, arity, handler, env})
    end
    Agent.update(Module.concat(__MODULE__, name), &(Dict.put(&1, {module, function, arity, env}, handler)))
    :ok
  end

  def list(name) do
    ref = :erlang.make_ref()
    case list(name, ref, self()) do
      {:ok, _pid} ->
        wait(ref)
      error ->
        error
    end
  end
  def list(name, ref, sender) when is_pid(sender) do
    hash = :crypto.rand_bytes(16)
    case PoolRing.get(name, hash) do
      {:ok, pid} ->
        send(pid, {:list, ref, sender})
        {:ok, pid}
      error ->
        error
    end
  end

  def call(name, module, function, arguments) do
    call(name, module, function, arguments, "prod")
  end
  def call(name, module, function, arguments, env) when is_binary(env) do
    ref = :erlang.make_ref()
    case call(name, module, function, arguments, ref, self(), env) do
      {:ok, _pid} ->
        wait(ref)
      error ->
        error
    end
  end
  def call(name, module, function, arguments, ref, sender) when is_pid(sender) do
    call(name, module, function, arguments, ref, sender, "prod")
  end
  def call(name, module, function, arguments, ref, sender, env) do
    hash = :erlang.phash2({module, function, arguments, env}) |> :binary.encode_unsigned
    case PoolRing.get(name, hash) do
      {:ok, pid} ->
        send(pid, {:call, module, function, arguments, ref, sender, env})
        {:ok, pid}
      error ->
        error
    end
  end

  defp wait(ref) do
    receive do
      {:ok, value, ^ref} ->
        {:ok, value}
      {:error, error, ^ref} ->
        {:error, error}
    after 10_000 ->
      {:error, :timeout}
    end
  end

  def init(opts, _) do
    ## TODO ping the server
    _ping = opts[:ping]
    Enum.each(opts[:registered], fn({{module, function, arity, env}, handler}) ->
      send(self(), {:register, module, function, arity, handler, env})
    end)
    {:ok, %__MODULE__{}}
  end

  def websocket_handle({:pong, _}, _conn, state) do
    {:ok, state}
  end
  def websocket_handle({:text, _}, _conn, state) do
    {:ok, state}
  end
  def websocket_handle({:binary, msg}, _conn, state) do
    msg
    |> Transport.decode
    |> handle_message(state)
  end

  def websocket_info({:register, module, function, arity, handler, env}, _conn, state) do
    module = to_string(module)
    function = to_string(function)
    handlers = state.handlers
    key = {module, function, arity, env}
    had_prev_key = Dict.has_key?(handlers, key)
    handlers = Dict.put(handlers, {module, function, arity, env}, handler)
    state = %{state | handlers: handlers}
    if !had_prev_key do
      msg = Transport.encode({:register, module, function, arity, env})
      {:reply, {:binary, msg}, state}
    else
      {:ok, state}
    end
  end
  def websocket_info({:list, ref, sender}, _conn, state) do
    id = gen_id
    reqs = Dict.put(state.reqs, id, {ref, sender})
    msg = Transport.encode({:list, id})
    {:reply, {:binary, msg}, %{state | reqs: reqs}}
  end
  def websocket_info({:call, module, function, arguments, ref, sender, env}, _conn, state) do
    id = gen_id
    module = to_string(module)
    function = to_string(function)
    reqs = Dict.put(state.reqs, id, {ref, sender})
    msg = Transport.encode({:req, id, module, function, arguments, env})
    {:reply, {:binary, msg}, %{state | reqs: reqs}}
  end
  def websocket_info(:ping, _conn, state) do
    {:reply, :ping, state}
  end

  def websocket_terminate(_reason, _conn, _state) do
    :ok
  end

  defp handle_message({:req, id, module, function, arguments, env}, state) do
    case Dict.get(state.handlers, {module, function, length(arguments), env}) do
      nil ->
        {:error, id, "#{module}:#{function}/#{length(arguments)} not registered"}
      handler ->
        ## TODO we should make this async
        res = apply(handler, arguments)
        msg = Transport.encode({:res, id, res})
        {:reply, {:binary, msg}, state}
    end
  end
  defp handle_message({:res, id, res}, state) do
    response(id, :ok, res, state)
  end
  defp handle_message({:error, id, code, error}, state) do
    response(id, :error, {code, error}, state)
  end

  def response(id, status, message, state) do
    reqs = state.reqs
    case Dict.get(reqs, id) do
      {ref, sender} ->
        send(sender, {status, message, ref})
        {:ok, %{state | reqs: Dict.delete(reqs, id)}}
      nil ->
        Logger.error("request #{id} not found")
        {:ok, state}
    end
  end

  defp gen_id do
    :crypto.rand_bytes(18) |> Base.encode64
  end
end
