defmodule DurgaClient.Mixfile do
  use Mix.Project

  def project do
    [app: :durga_client,
     version: "0.1.0",
     elixir: "~> 1.0",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  def application do
    [applications: [:logger, :pool_ring]]
  end

  defp deps do
    [{:pool_ring, "~> 0.1.0"},
     {:websocket_client, github: "jeremyong/websocket_client", ref: "f6892c8b55004008ce2d52be7d98b156f3e34569"},
     {:durga_transport, "~> 1.0.0"},
     {:msgpack, github: "msgpack/msgpack-erlang"},]
  end
end
