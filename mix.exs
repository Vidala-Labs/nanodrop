defmodule Nanodrop.MixProject do
  use Mix.Project

  def project do
    [
      app: :nanodrop,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:usb, "~> 0.2.1", optional: true},
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
      links: %{}
    ]
  end
end
