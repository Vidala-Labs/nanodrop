defmodule Nanodrop.Functions.Turbidity do
  @moduledoc """
  Turbidity/scattering function: A(λ) = a / (λ + c)^n + b

  Models baseline scattering in spectra due to turbidity or particulates.

  - `a` - scattering coefficient (amplitude)
  - `c` - wavelength offset
  - `n` - wavelength exponent (typically 4 for Rayleigh scattering)
  - `b` - baseline offset
  """

  @behaviour Access

  defstruct a: 0.0,
            c: 0.0,
            n: 4.0,
            b: 0.0

  @type t :: %__MODULE__{
          a: float(),
          c: float(),
          n: float(),
          b: float()
        }

  @doc """
  Evaluate the turbidity function at a given wavelength.
  """
  @spec evaluate(t(), float()) :: float()
  def evaluate(%__MODULE__{a: a, c: c, n: n, b: b}, wavelength) do
    a / :math.pow(wavelength + c, n) + b
  end

  @doc """
  Evaluate the turbidity function at multiple wavelengths.
  """
  @spec evaluate_all(t(), [float()]) :: [float()]
  def evaluate_all(%__MODULE__{} = turbidity, wavelengths) do
    Enum.map(wavelengths, &evaluate(turbidity, &1))
  end

  # Access behaviour implementation

  @impl Access
  def fetch(%__MODULE__{} = turbidity, key) when key in [:a, :c, :n, :b] do
    {:ok, Map.get(turbidity, key)}
  end

  def fetch(%__MODULE__{}, _key), do: :error

  @impl Access
  def get_and_update(%__MODULE__{} = turbidity, key, fun) when key in [:a, :c, :n, :b] do
    current = Map.get(turbidity, key)
    {get, update} = fun.(current)
    {get, Map.put(turbidity, key, update)}
  end

  def get_and_update(%__MODULE__{}, key, _fun) do
    raise KeyError, key: key, term: __MODULE__
  end

  @impl Access
  def pop(%__MODULE__{} = turbidity, key) when key in [:a, :c, :n, :b] do
    {Map.get(turbidity, key), Map.put(turbidity, key, nil)}
  end

  def pop(%__MODULE__{}, key) do
    raise KeyError, key: key, term: __MODULE__
  end
end
