defmodule Rinha2026.MixProject do
  use Mix.Project

  def project do
    [
      app: :rinha_2026,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      compilers: [:elixir_make] ++ Mix.compilers()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Rinha2026, []}
    ]
  end

  defp deps do
    [
      {:cowboy, "~> 2.10"},
      {:elixir_make, "~> 0.7", runtime: false}
    ]
  end

  defp releases do
    [
      rinha_2026: [
        include_executables_for: [:unix],
        strip_beam: Mix.env() == :prod
      ]
    ]
  end
end
