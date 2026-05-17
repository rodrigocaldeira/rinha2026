defmodule Rinha2026 do
  use Application

  def start(_type, _args) do
    priv_dir = :code.priv_dir(:rinha_2026)

    dataset_path = :filename.join(priv_dir, "references_bucketed.bin")
    offsets_path = :filename.join(priv_dir, "bucket_offsets.bin")
    ivf_dataset_path = :filename.join(priv_dir, "references_ivf.bin")
    ivf_offsets_path = :filename.join(priv_dir, "ivf_offsets.bin")
    ivf_centroids_path = :filename.join(priv_dir, "ivf_centroids.bin")

    :ok =
      Rinha2026.NIF.load_dataset(
        dataset_path,
        offsets_path,
        ivf_dataset_path,
        ivf_offsets_path,
        ivf_centroids_path
      )

    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {:_, Rinha2026.Handler, []}
         ]}
      ])

    {_, http_config} = config = get_http_config()

    children = [
      %{
        id: :cowboy,
        start:
          {:cowboy, :start_clear,
           [
             :http,
             http_config,
             %{
               env: %{dispatch: dispatch},
               max_connections: 2048,
               request_timeout: 5_000,
               inactivity_timeout: 5_000
             }
           ]}
      }
    ]

    start_supervisor(config, children)
  end

  defp get_http_config do
    socket_opts = [
      {:nodelay, true},
      {:backlog, 2048}
    ]

    case Application.fetch_env!(:rinha_2026, :env) do
      :prod ->
        socket =
          Application.fetch_env!(:rinha_2026, :socket)

        _ = File.rm(socket)

        :ok = File.mkdir_p!("/sockets")

        config = %{
          num_acceptors: 2,
          socket_opts:
            [
              ip: {:local, socket}
            ] ++ socket_opts
        }

        {:socket, config}

      _ ->
        port =
          Application.fetch_env!(:rinha_2026, :port)

        config = %{
          num_acceptors: 2,
          socket_opts:
            [
              port: port
            ] ++ socket_opts
        }

        {:http, config}
    end
  end

  defp start_supervisor({:http, _}, children) do
    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp start_supervisor({:socket, %{socket_opts: socket_opts}}, children) do
    {:local, socket} =
      Keyword.get(socket_opts, :ip)

    sup =
      Supervisor.start_link(
        children,
        strategy: :one_for_one
      )

    wait_for_socket(socket)

    File.chmod!(socket, 0o777)

    sup
  end

  defp wait_for_socket(path) do
    unless File.exists?(path) do
      Process.sleep(10)
      wait_for_socket(path)
    end
  end
end
