defmodule Nanodrop.MixProject do
  use Mix.Project

  def project do
    [
      app: :nanodrop,
      version: "0.3.1",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/_support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:usb, "~> 0.2.1", optional: true},
      {:vix, "~> 0.31"},
      {:jason, "~> 1.4"},
      {:protoss, "~> 1.1"},
      {:nx, "~> 0.9"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp description do
    """
    Elixir library for interfacing with NanoDrop 1000 spectrophotometers over USB.
    Uses the Ocean Optics OOI protocol.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/Vidala-Labs/nanodrop"
      }
    ]
  end
end
