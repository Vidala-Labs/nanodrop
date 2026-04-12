defmodule Nanodrop.Spectrum do
  @moduledoc """
  Absorbance spectrum data structure.

  Contains wavelengths (nm) and corresponding absorbance values,
  calculated from raw intensity data using Beer-Lambert law:

      A = -log10((sample - dark) / (blank - dark))

  """

  @behaviour Access

  defstruct wavelengths: [],
            absorbance: [],
            timestamp: nil

  @type t :: %__MODULE__{
          wavelengths: [float()],
          absorbance: [float()],
          timestamp: DateTime.t() | nil
        }

  @doc """
  Creates a spectrum from wavelength and absorbance lists.
  """
  @spec new([float()], [float()]) :: t()
  def new(wavelengths, absorbance) when length(wavelengths) == length(absorbance) do
    %__MODULE__{
      wavelengths: wavelengths,
      absorbance: absorbance,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Returns the absorbance at a specific wavelength (nearest match).
  """
  @spec absorbance_at(t(), float()) :: float()
  def absorbance_at(%__MODULE__{wavelengths: wls, absorbance: abs}, target_wavelength) do
    idx =
      wls
      |> Enum.with_index()
      |> Enum.min_by(fn {wl, _} -> abs(wl - target_wavelength) end)
      |> elem(1)

    Enum.at(abs, idx)
  end

  @doc """
  Returns the wavelength range as {min, max}.
  """
  @spec wavelength_range(t()) :: {float(), float()}
  def wavelength_range(%__MODULE__{wavelengths: wls}) do
    {Enum.min(wls), Enum.max(wls)}
  end

  @doc """
  Filters the spectrum to a wavelength range.
  """
  @spec filter_range(t(), float(), float()) :: t()
  def filter_range(%__MODULE__{wavelengths: wls, absorbance: abs, timestamp: ts}, min_wl, max_wl) do
    {filtered_wls, filtered_abs} =
      Enum.zip(wls, abs)
      |> Enum.filter(fn {wl, _} -> wl >= min_wl and wl <= max_wl end)
      |> Enum.unzip()

    %__MODULE__{wavelengths: filtered_wls, absorbance: filtered_abs, timestamp: ts}
  end

  @doc """
  Subtracts baseline values from absorbance.

  Accepts either another Spectrum or a list of values.
  """
  @spec subtract(t(), t() | [float()]) :: t()
  def subtract(%__MODULE__{} = spectrum, %__MODULE__{absorbance: baseline_abs}) do
    subtract(spectrum, baseline_abs)
  end

  def subtract(%__MODULE__{wavelengths: wls, absorbance: abs, timestamp: ts}, baseline)
      when is_list(baseline) do
    new_abs =
      Enum.zip(abs, baseline)
      |> Enum.map(fn {a, b} -> max(a - b, 0.0) end)

    %__MODULE__{wavelengths: wls, absorbance: new_abs, timestamp: ts}
  end

  @doc """
  Returns the number of data points.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{wavelengths: wls}), do: Kernel.length(wls)

  @doc """
  Finds the wavelength with maximum absorbance.
  """
  @spec peak_wavelength(t()) :: float()
  def peak_wavelength(%__MODULE__{wavelengths: wls, absorbance: abs}) do
    {_max_abs, idx} =
      abs
      |> Enum.with_index()
      |> Enum.max_by(fn {a, _} -> a end)

    Enum.at(wls, idx)
  end

  # Access behaviour implementation

  @impl Access
  def fetch(%__MODULE__{} = spectrum, key) when key in [:wavelengths, :absorbance, :timestamp] do
    {:ok, Map.get(spectrum, key)}
  end

  def fetch(%__MODULE__{}, _key), do: :error

  @impl Access
  def get_and_update(%__MODULE__{} = spectrum, key, fun)
      when key in [:wavelengths, :absorbance, :timestamp] do
    current = Map.get(spectrum, key)
    {get, update} = fun.(current)
    {get, Map.put(spectrum, key, update)}
  end

  def get_and_update(%__MODULE__{}, key, _fun) do
    raise KeyError, key: key, term: __MODULE__
  end

  @impl Access
  def pop(%__MODULE__{} = spectrum, key) when key in [:wavelengths, :absorbance, :timestamp] do
    {Map.get(spectrum, key), Map.put(spectrum, key, nil)}
  end

  def pop(%__MODULE__{}, key) do
    raise KeyError, key: key, term: __MODULE__
  end
end
