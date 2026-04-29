defmodule Nanodrop.Baseline do
  @moduledoc """
  Baseline correction using Rayleigh scattering turbidity model.

  Fits turbidity baseline to:

      baseline(λ) = A / (λ + c)^4 + b

  Using Levenberg-Marquardt nonlinear least squares over two segments
  where peak contribution is minimal:
  - 220-230nm (left edge)
  - 300-400nm (right side)

  The corrected spectrum is simply: raw - baseline
  A260 is read directly from the corrected spectrum.
  """

  alias Nanodrop.Functions.Turbidity
  alias Nanodrop.Math
  alias Nanodrop.Spectrum

  @doc """
  Corrects a spectrum for baseline using Rayleigh turbidity fit.

  ## Options

  - `:windows` - List of `{min, max}` wavelength ranges for fitting
    (default: `[{220.0, 230.0}, {300.0, 400.0}]`)

  Returns a tuple of `{spectrum, corrected_spectrum, turbidity}`:
  - `spectrum` - the original input spectrum
  - `corrected_spectrum` - baseline-subtracted spectrum
  - `turbidity` - fitted turbidity parameters (%Turbidity{})
  """
  @spec correct(Spectrum.t(), keyword()) :: {Spectrum.t(), Spectrum.t(), Turbidity.t()}
  def correct(%Spectrum{} = spectrum, opts \\ []) do
    windows = Keyword.get(opts, :windows, [{220.0, 230.0}, {300.0, 400.0}])

    wavelengths = spectrum.wavelengths
    absorbance = spectrum.absorbance

    # Fit turbidity using specified windows
    turbidity = fit_turbidity(wavelengths, absorbance, windows)

    # Calculate baseline
    baseline = Turbidity.evaluate_all(turbidity, wavelengths)

    # Corrected = raw - baseline
    corrected_absorbance =
      Enum.zip(absorbance, baseline)
      |> Enum.map(fn {abs, bl} -> abs - bl end)

    corrected_spectrum = %Spectrum{
      wavelengths: wavelengths,
      absorbance: corrected_absorbance,
      timestamp: spectrum.timestamp
    }

    {spectrum, corrected_spectrum, turbidity}
  end

  @doc """
  Fits turbidity parameters using Levenberg-Marquardt over specified windows.

  Model: A(λ) = A / (λ + c)^4 + b

  Parameters:
  - A (amplitude)
  - c (wavelength offset)
  - b (y-offset)
  """
  def fit_turbidity(wavelengths, absorbance, windows) do
    # Extract data points from windows
    data = Enum.zip(wavelengths, absorbance)

    {x_data, y_data} =
      data
      |> Enum.filter(fn {wl, _} -> in_windows?(wl, windows) end)
      |> Enum.unzip()

    # Model: f(λ, [A, c, b]) = A / (λ + c)^4 + b
    model = fn lambda, [a, c, b] ->
      a / :math.pow(lambda + c, 4) + b
    end

    # Jacobian: [∂f/∂A, ∂f/∂c, ∂f/∂b]
    jacobian = fn lambda, [a, c, _b] ->
      denom = lambda + c
      [
        1.0 / :math.pow(denom, 4),           # ∂f/∂A
        -4.0 * a / :math.pow(denom, 5),      # ∂f/∂c
        1.0                                   # ∂f/∂b
      ]
    end

    # Initial guess (from Python: [1e9, 0, 0])
    initial = [1.0e9, 0.0, 0.0]

    case Math.levenberg_marquardt(x_data, y_data, model, jacobian, initial) do
      {:ok, %{params: [a, c, b]}} ->
        %Turbidity{a: a, c: c, n: 4.0, b: b}

      {:error, _reason} ->
        # Fallback to zeros if fit fails
        %Turbidity{a: 0.0, c: 0.0, n: 4.0, b: 0.0}
    end
  end

  defp in_windows?(wl, windows) do
    Enum.any?(windows, fn {min, max} -> wl >= min and wl <= max end)
  end
end
