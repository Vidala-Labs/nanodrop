defmodule Nanodrop.Functions.Gaussian do
  @moduledoc """
  Gaussian function: A(λ) = amplitude * exp(-(λ - center)² / (2σ²))

  Models absorption peaks in spectra.
  """

  @behaviour Access

  defstruct amplitude: 0.0,
            center: 260.0,
            sigma: 30.0

  @type t :: %__MODULE__{
          amplitude: float(),
          center: float(),
          sigma: float()
        }

  @doc """
  Evaluate the Gaussian at a given wavelength.
  """
  @spec evaluate(t(), float()) :: float()
  def evaluate(%__MODULE__{amplitude: amp, center: ctr, sigma: sig}, wavelength) do
    amp * :math.exp(-:math.pow(wavelength - ctr, 2) / (2 * sig * sig))
  end

  @doc """
  Evaluate the Gaussian at multiple wavelengths.
  """
  @spec evaluate_all(t(), [float()]) :: [float()]
  def evaluate_all(%__MODULE__{} = gaussian, wavelengths) do
    Enum.map(wavelengths, &evaluate(gaussian, &1))
  end

  # Access behaviour implementation

  @impl Access
  def fetch(%__MODULE__{} = gaussian, key) when key in [:amplitude, :center, :sigma] do
    {:ok, Map.get(gaussian, key)}
  end

  def fetch(%__MODULE__{}, _key), do: :error

  @impl Access
  def get_and_update(%__MODULE__{} = gaussian, key, fun) when key in [:amplitude, :center, :sigma] do
    current = Map.get(gaussian, key)
    {get, update} = fun.(current)
    {get, Map.put(gaussian, key, update)}
  end

  def get_and_update(%__MODULE__{}, key, _fun) do
    raise KeyError, key: key, term: __MODULE__
  end

  @impl Access
  def pop(%__MODULE__{} = gaussian, key) when key in [:amplitude, :center, :sigma] do
    {Map.get(gaussian, key), Map.put(gaussian, key, nil)}
  end

  def pop(%__MODULE__{}, key) do
    raise KeyError, key: key, term: __MODULE__
  end
end
