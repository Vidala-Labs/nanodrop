defmodule Nanodrop.Baseline do
  @moduledoc """
  Baseline correction using joint Gaussian + turbidity fitting.

  Fits the full spectrum to:

      A(λ) = amplitude * exp(-(λ - center)² / (2σ²)) + a * λ^(-n) + b

  Where:
  - Gaussian models the absorption peak (center constrained near 260nm for DNA)
  - Turbidity term `a * λ^(-n) + b` models scattering/baseline

  Uses gradient descent optimization via Nx.
  """

  import Nx.Defn

  alias Nanodrop.Functions.Gaussian
  alias Nanodrop.Functions.Turbidity
  alias Nanodrop.Spectrum

  @default_center 260.0
  @center_constraint 10.0

  @doc """
  Corrects a spectrum for baseline using joint Gaussian + turbidity fit.

  ## Options

  - `:center` - Expected peak center wavelength (default: 260.0 for DNA)
  - `:center_constraint` - How far center can move from expected (default: 10.0nm)
  - `:learning_rate` - Gradient descent learning rate (default: 0.001)
  - `:iterations` - Number of optimization iterations (default: 1000)

  Returns a tuple of `{spectrum, corrected_spectrum, gaussian, turbidity}`:
  - `spectrum` - the original input spectrum
  - `corrected_spectrum` - baseline-subtracted spectrum (turbidity removed)
  - `gaussian` - fitted Gaussian parameters (%Gaussian{})
  - `turbidity` - fitted turbidity parameters (%Turbidity{})
  """
  @spec correct(Spectrum.t(), keyword()) :: {Spectrum.t(), Spectrum.t(), Gaussian.t(), Turbidity.t()}
  def correct(%Spectrum{} = spectrum, opts \\ []) do
    center = Keyword.get(opts, :center, @default_center)
    center_constraint = Keyword.get(opts, :center_constraint, @center_constraint)
    learning_rate = Keyword.get(opts, :learning_rate, 0.001)
    iterations = Keyword.get(opts, :iterations, 1000)

    wavelengths = spectrum.wavelengths
    absorbance = spectrum.absorbance

    # Convert to Nx tensors
    wl_tensor = Nx.tensor(wavelengths, type: :f32)
    abs_tensor = Nx.tensor(absorbance, type: :f32)

    # Initial parameter estimates
    init_params = initial_params(wavelengths, absorbance, center)

    # Optimize
    final_params =
      optimize(
        wl_tensor,
        abs_tensor,
        init_params,
        center,
        center_constraint,
        learning_rate,
        iterations
      )

    # Extract results
    %{gaussian: gaussian, turbidity: turbidity} = extract_params(final_params)

    # Calculate baseline (turbidity only - what we subtract)
    baseline = Turbidity.evaluate_all(turbidity, wavelengths)

    # Corrected = raw - baseline (turbidity only)
    corrected_absorbance =
      Enum.zip(absorbance, baseline)
      |> Enum.map(fn {abs, bl} -> max(abs - bl, 0.0) end)

    corrected_spectrum = %Spectrum{
      wavelengths: wavelengths,
      absorbance: corrected_absorbance,
      timestamp: spectrum.timestamp
    }

    {spectrum, corrected_spectrum, gaussian, turbidity}
  end

  defp initial_params(wavelengths, absorbance, center) do
    # Find approximate peak
    {peak_abs, peak_idx} =
      absorbance
      |> Enum.with_index()
      |> Enum.max_by(fn {abs, _} -> abs end)

    peak_wl = Enum.at(wavelengths, peak_idx)

    # Estimate baseline from edges
    edge_abs = Enum.take(absorbance, 10) ++ Enum.take(absorbance, -10)
    baseline_estimate = Enum.sum(edge_abs) / length(edge_abs)

    # Initial guesses
    %{
      amplitude: peak_abs - baseline_estimate,
      center: min(max(peak_wl, center - 20), center + 20),
      sigma: 30.0,
      a: 1000.0,
      n: 2.0,
      b: baseline_estimate
    }
  end

  defp optimize(wavelengths, absorbance, init_params, center, center_constraint, lr, iterations) do
    # Pack parameters into tensor [amplitude, center, sigma, a, n, b]
    params =
      Nx.tensor(
        [
          init_params.amplitude,
          init_params.center,
          init_params.sigma,
          init_params.a,
          init_params.n,
          init_params.b
        ],
        type: :f32
      )

    center_t = Nx.tensor(center, type: :f32)
    constraint_t = Nx.tensor(center_constraint, type: :f32)
    lr_t = Nx.tensor(lr, type: :f32)

    # Run optimization loop
    {final_params, _} =
      Enum.reduce(1..iterations, {params, nil}, fn _, {p, _} ->
        {new_p, loss} = gradient_step(wavelengths, absorbance, p, center_t, constraint_t, lr_t)
        {new_p, loss}
      end)

    final_params
  end

  defnp gradient_step(wavelengths, absorbance, params, center, constraint, lr) do
    # Compute gradients
    {loss, grads} =
      value_and_grad(params, fn p ->
        loss_fn(wavelengths, absorbance, p, center, constraint)
      end)

    # Clip gradients to prevent explosion
    grads = Nx.clip(grads, -10.0, 10.0)

    # Update parameters
    new_params = params - lr * grads

    # Enforce constraints
    new_params = constrain_params(new_params, center, constraint)

    {new_params, loss}
  end

  defnp loss_fn(wavelengths, absorbance, params, center, constraint) do
    predicted = model(wavelengths, params)
    residuals = absorbance - predicted

    # MSE loss
    mse = Nx.mean(residuals * residuals)

    # Soft constraint on center staying near expected
    center_param = params[1]
    center_penalty = Nx.pow((center_param - center) / constraint, 2) * 0.1

    mse + center_penalty
  end

  defnp model(wavelengths, params) do
    amplitude = params[0]
    center = params[1]
    sigma = params[2]
    a = params[3]
    n = params[4]
    b = params[5]

    # Gaussian peak
    gaussian = amplitude * Nx.exp(-Nx.pow(wavelengths - center, 2) / (2 * sigma * sigma))

    # Turbidity: a * λ^(-n) + b
    turbidity = a * Nx.pow(wavelengths, -n) + b

    gaussian + turbidity
  end

  defnp constrain_params(params, center, constraint) do
    amplitude = Nx.max(params[0], 0.001)
    center_p = Nx.clip(params[1], center - constraint, center + constraint)
    sigma = Nx.clip(params[2], 5.0, 100.0)
    a = Nx.max(params[3], 0.0)
    n = Nx.clip(params[4], 0.5, 6.0)
    b = params[5]

    Nx.stack([amplitude, center_p, sigma, a, n, b])
  end

  defp extract_params(tensor) do
    [amplitude, center, sigma, a, n, b] = Nx.to_flat_list(tensor)

    %{
      gaussian: %Gaussian{amplitude: amplitude, center: center, sigma: sigma},
      turbidity: %Turbidity{a: a, n: n, b: b}
    }
  end
end
