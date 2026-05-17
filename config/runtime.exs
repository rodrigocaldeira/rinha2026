import Config

port =
  System.get_env("PORT", "9999")
  |> String.to_integer()

socket =
  System.get_env("SOCKET", "") |> String.to_charlist()

config :rinha_2026,
  env: config_env(),
  port: port,
  socket: socket
