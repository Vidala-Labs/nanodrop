defmodule Nanodrop do
  @moduledoc """
  Elixir library for interfacing with NanoDrop 1000 spectrophotometers.

  The NanoDrop 1000 internally uses an Ocean Optics USB2000 spectrometer and
  communicates via the OOI (Ocean Optics Interface) protocol over USB.

  ## Quick Start

      # Start the server (connects to first available device)
      {:ok, pid} = Nanodrop.start_link()

      # Calibrate with water/buffer on pedestal (takes dark + blank in one shot)
      :ok = Nanodrop.calibrate(pid)

      # Measure a sample (includes full spectrum in result)
      {:ok, result} = Nanodrop.measure_nucleic_acid(pid)
      # => %{a260: 1.5, a280: 0.75, a260_a280: 2.0, concentration_ng_ul: 75.0, spectrum: ...}

      # Or get the spectrum and analyze it
      {:ok, spectrum} = Nanodrop.get_spectrum(pid)
      abs_280 = Nanodrop.absorbance_at(spectrum, 280.0)

  ## Device Identification

  - USB Vendor ID: `0x2457` (Ocean Optics)
  - USB Product ID: `0x1002` (USB2000)

  ## Calibration

  For accurate absorbance measurements, you need two reference spectra:

  1. **Dark** - Detector baseline with no light (close pedestal arm, no sample)
  2. **Blank** - 100% transmission through solvent (water/buffer on pedestal)

  Absorbance is then calculated as: `A = -log10((sample - dark) / (blank - dark))`

  ## Distributed Operation

  This module is designed to work over Erlang distribution. The NanoDrop server
  can run on a dedicated node (e.g., a Nerves device with USB access) while
  being controlled from a remote node.

  ### Direct node reference

      # On the device node (e.g., nanodrop@device.local)
      {:ok, pid} = Nanodrop.start_link(name: Nanodrop)

      # From a remote node
      Nanodrop.set_dark({Nanodrop, :"nanodrop@device.local"})
      Nanodrop.set_blank({Nanodrop, :"nanodrop@device.local"})
      {:ok, result} = Nanodrop.measure_nucleic_acid({Nanodrop, :"nanodrop@device.local"})

  ### Global registration

      # On the device node
      {:ok, pid} = Nanodrop.start_link(name: {:global, :nanodrop})

      # From any connected node
      Nanodrop.set_dark({:global, :nanodrop})
      {:ok, result} = Nanodrop.measure_nucleic_acid({:global, :nanodrop})

  ### Process groups (pg)

      # On the device node
      {:ok, pid} = Nanodrop.start_link()
      :pg.join(:spectrophotometers, pid)

      # From any connected node
      [pid | _] = :pg.get_members(:spectrophotometers)
      {:ok, result} = Nanodrop.measure_nucleic_acid(pid)

  All API functions accept any valid `GenServer.server()` reference.
  """

  use GenServer

  alias Nanodrop.Baseline
  alias Nanodrop.Device
  alias Nanodrop.OOI
  alias Nanodrop.Spectrum

  @default_integration_time 100_000
  @calibration_max_age_seconds 30 * 60
  @measurement_staleness_seconds 5 * 60

  @type wavelength_calibration :: %{
          intercept: float(),
          first_coefficient: float(),
          second_coefficient: float(),
          third_coefficient: float()
        }

  defstruct ~w[device serial_number wavelength_calibration dark blank integration_time last_measurement_at]a

  @typep state :: %__MODULE__{
           device: Device.t(),
           serial_number: String.t(),
           wavelength_calibration: wavelength_calibration(),
           dark: OOI.t() | nil,
           blank: OOI.t() | nil,
           integration_time: pos_integer(),
           last_measurement_at: DateTime.t() | nil
         }

  # ===========================================================================
  # Boilerplate & Initialization
  # ===========================================================================

  @doc """
  Starts the NanoDrop server and connects to a device.

  Returns `:ignore` if running in network-only mode or if the USB library
  is not available. This allows the application to start on nodes that
  don't have USB access (e.g., remote control nodes in a distributed setup).

  ## Options

  - `:device` - A device info map from `Nanodrop.list_devices/0`. If not provided,
    connects to the first available device.
  - `:name` - Optional name for the GenServer.

  ## Configuration

  - `:network_only` - When set to `true` in application config, the server
    will return `:ignore` instead of connecting to USB. This is useful for
    nodes that only need to call a remote NanoDrop server over distribution.

        config :nanodrop, network_only: true
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    server_opts = Keyword.take(opts, [:name])

    if network_only?() do
      :ignore
    else
      GenServer.start_link(__MODULE__, opts, server_opts)
    end
  end

  @spec network_only?() :: boolean()
  defp network_only? do
    Application.get_env(:nanodrop, :network_only, false) or not usb_available?()
  end

  @spec usb_available?() :: boolean()
  defp usb_available?, do: Code.ensure_loaded?(:usb)

  @impl true
  def init(opts) do
    device_info = Keyword.get(opts, :device)

    with {:ok, device} <- Device.open(device_info),
         {:ok, state} <- initialize_device(device) do
      {:ok, state}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  # USB device handle is automatically closed when owner process terminates
  # (NIF uses enif_monitor_process for cleanup)

  # ===========================================================================
  # API + Implementations
  # ===========================================================================

  @type absorbance_spectrum :: %{
          absorbance: [float()],
          wavelengths: [float()],
          timestamp: DateTime.t()
        }

  @spec list_devices() :: [Device.device_info()]
  @spec info(GenServer.server()) :: map()
  @spec serial_number(GenServer.server()) :: String.t()
  @spec wavelength_calibration(GenServer.server()) :: map()
  @spec set_integration_time(GenServer.server(), pos_integer()) :: :ok | {:error, term()}
  @spec set_dark(GenServer.server()) :: :ok | {:error, term()}
  @spec set_blank(GenServer.server()) :: :ok | {:error, term()}
  @spec calibrate(GenServer.server()) :: :ok | {:error, term()}
  @spec calibrated?(GenServer.server()) :: boolean()
  @spec get_raw_spectrum(GenServer.server()) :: {:ok, Spectrum.t()} | {:error, term()}
  @spec get_spectrum(GenServer.server()) :: {:ok, absorbance_spectrum()} | {:error, term()}
  @spec absorbance_at(absorbance_spectrum(), float()) :: float()
  @spec measure_nucleic_acid(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  @spec measure_protein(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Lists all connected NanoDrop devices.

  Returns a list of device info maps that can be used with `start_link/1`.

  ## Example

      Nanodrop.list_devices()
      #=> [%{vendor_id: 9303, product_id: 4098, bus: 1, address: 19, device_ref: #Reference<...>}]
  """
  defdelegate list_devices(), to: Device

  @doc """
  Returns device information.
  """
  def info(server) do
    GenServer.call(server, :info)
  end

  @spec info_impl(GenServer.from(), state()) :: {:reply, map(), state()}
  defp info_impl(_from, state) do
    now = DateTime.utc_now()

    calibrated_at =
      case {state.dark, state.blank} do
        {dark = %{}, blank = %{}} -> Enum.min([dark.timestamp, blank.timestamp], DateTime)
        _ -> nil
      end

    info = %{
      serial_number: state.serial_number,
      wavelength_calibration: state.wavelength_calibration,
      integration_time: state.integration_time,
      calibrated: _calibrated?(state, now),
      calibrated_at: calibrated_at,
      last_measurement_at: state.last_measurement_at
    }

    {:reply, info, state}
  end

  @doc """
  Returns the device serial number.
  """
  def serial_number(server) do
    GenServer.call(server, :serial_number)
  end

  @spec serial_number_impl(GenServer.from(), state()) :: {:reply, String.t(), state()}
  defp serial_number_impl(_from, state) do
    {:reply, state.serial_number, state}
  end

  @doc """
  Returns the wavelength calibration coefficients.
  """
  def wavelength_calibration(server) do
    GenServer.call(server, :wavelength_calibration)
  end

  @spec wavelength_calibration_impl(GenServer.from(), state()) ::
          {:reply, Spectrum.calibration(), state()}
  defp wavelength_calibration_impl(_from, state) do
    {:reply, state.wavelength_calibration, state}
  end

  @doc """
  Sets the integration time in microseconds.

  Valid range: 3,000 - 655,350,000 µs.
  Default is 100,000 µs (100ms).
  """
  def set_integration_time(server, microseconds) do
    GenServer.call(server, {:set_integration_time, microseconds})
  end

  @spec set_integration_time_impl(pos_integer(), GenServer.from(), state()) ::
          {:reply, :ok | {:error, term()}, state()}
  defp set_integration_time_impl(microseconds, _from, state) do
    case OOI.set_integration_time(state.device, microseconds) do
      :ok ->
        {:reply, :ok, %{state | integration_time: microseconds}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @doc """
  Measures and stores the dark spectrum.

  Call this with the light path blocked (pedestal arm closed, nothing on pedestal).
  """
  def set_dark(server) do
    GenServer.call(server, {:set_spectrum, :dark})
  end

  @doc """
  Measures and stores the blank/reference spectrum.

  Call this with your reference solvent (water, buffer) on the pedestal.
  """
  def set_blank(server) do
    GenServer.call(server, {:set_spectrum, :blank})
  end

  @doc """
  Performs full calibration in one shot (dark + blank).

  Call this with your reference solvent (water, buffer) on the pedestal
  and the arm closed. This will:

  1. Take a dark measurement (no lamp flash) - detector baseline
  2. Take a blank measurement (lamp flashes) - reference through solvent

  This is more efficient than calling `set_dark/1` and `set_blank/1` separately
  since both measurements are taken with the same sample in place.
  """
  def calibrate(server) do
    GenServer.call(server, :calibrate)
  end

  # Minimum blank intensity to consider calibration valid (strobe fired)
  @min_blank_intensity 2500

  @spec calibrate_impl(GenServer.from(), state()) ::
          {:reply, :ok | {:error, term()}, state()}
  defp calibrate_impl(_from, state) do
    # Take dark spectrum first (no strobe), then blank (with strobe)
    # Both measurements use the same sample in place
    with {:ok, dark} <- OOI.get_dark_spectrum(state.device),
         {:ok, blank} <- OOI.get_spectrum(state.device),
         :ok <- validate_blank_intensity(blank) do
      {:reply, :ok, %{state | dark: dark, blank: blank}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp validate_blank_intensity(blank) do
    max_intensity = Enum.max(blank.raw_pixels)

    if max_intensity >= @min_blank_intensity do
      :ok
    else
      {:error, {:calibration_failed, :low_blank_intensity, max_intensity}}
    end
  end

  # implementation for both dark and blank spectrum
  @spec set_spectrum_impl(:dark | :blank, GenServer.from(), state()) ::
          {:reply, :ok | {:error, term()}, state()}
  defp set_spectrum_impl(:dark, _from, state) do
    # Dark measurement: no strobe/lamp - measures detector baseline
    case OOI.get_dark_spectrum(state.device) do
      {:ok, spectrum} ->
        {:reply, :ok, %{state | dark: spectrum}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp set_spectrum_impl(:blank, _from, state) do
    # Blank measurement: strobe/lamp enabled - measures through reference solvent
    case OOI.get_spectrum(state.device) do
      {:ok, spectrum} ->
        {:reply, :ok, %{state | blank: spectrum}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @doc """
  Returns whether the device is calibrated (has both dark and blank spectra).
  """
  def calibrated?(server) do
    GenServer.call(server, :calibrated?)
  end

  @spec calibrated_impl(GenServer.from(), state()) :: {:reply, boolean(), state()}
  defp calibrated_impl(_from, state) do
    {:reply, _calibrated?(state, DateTime.utc_now()), state}
  end

  @doc """
  Acquires a raw spectrum from the device.

  Returns pixel intensity values without any processing.
  """
  def get_raw_spectrum(server) do
    GenServer.call(server, :get_raw_spectrum)
  end

  @spec get_raw_spectrum_impl(GenServer.from(), state()) ::
          {:reply, {:ok, OOI.t()} | {:error, term()}, state()}
  defp get_raw_spectrum_impl(_from, state) do
    case OOI.get_spectrum(state.device) do
      {:ok, ooi} ->
        {:reply, {:ok, ooi}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @doc """
  Acquires a spectrum and calculates absorbance values.

  Requires calibration (dark and blank spectra).
  Returns a spectrum with absorbance and wavelength values for each pixel.

  This is the single GenServer call for spectrum acquisition. Use this
  with `absorbance_at/2` or the measurement functions for analysis.
  """
  def get_spectrum(server) do
    GenServer.call(server, :get_spectrum)
  end

  @spec get_spectrum_impl(GenServer.from(), state()) ::
          {:reply, {:ok, absorbance_spectrum()} | {:error, term()}, state()}
  defp get_spectrum_impl(_from, state) do
    now = DateTime.utc_now()

    with :ok <- check_calibration(state, now),
         {:ok, spectrum} <- OOI.get_spectrum(state.device) do
      absorbance = calculate_absorbance_spectrum(spectrum, state)
      {:reply, {:ok, absorbance}, %{state | last_measurement_at: now}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @doc """
  Returns the absorbance at a specific wavelength from a spectrum.

  Wavelength is in nanometers. This is a pure function that operates
  on a spectrum returned by `get_spectrum/1`.
  """
  def absorbance_at(spectrum, wavelength_nm) do
    Spectrum.absorbance_at(spectrum, wavelength_nm)
  end

  @doc """
  Measures nucleic acid concentration.

  Returns A260, A280, A260/A280 ratio, estimated concentration, and the full spectrum.
  Uses the approximation: 1 A260 = 50 ng/µL for dsDNA (1mm path).

  ## Options

  - `:factor` - Conversion factor (default: 50.0 for dsDNA, use 33.0 for ssDNA, 40.0 for RNA)

  Requires calibration.
  """
  def measure_nucleic_acid(server, opts \\ []) do
    with {:ok, spectrum} <- get_spectrum(server) do
      # Apply baseline correction
      {_original, corrected_spectrum, turbidity} = Baseline.correct(spectrum)

      # Use corrected values for A260/A280
      a260 = absorbance_at(corrected_spectrum, 260.0)
      a280 = absorbance_at(corrected_spectrum, 280.0)

      # For A260/A230, use only b-offset correction (not full baseline)
      raw_a260 = absorbance_at(spectrum, 260.0)
      raw_a230 = absorbance_at(spectrum, 230.0)
      a260_for_230_ratio = raw_a260 - turbidity.b
      a230_for_ratio = raw_a230 - turbidity.b

      factor = Keyword.get(opts, :factor, 50.0)

      result = %{
        a260: a260,
        a280: a280,
        a260_a280: safe_ratio(a260, a280),
        a260_a230: safe_ratio(a260_for_230_ratio, a230_for_ratio),
        concentration_ng_ul: a260 * factor,
        spectrum: spectrum,
        corrected_spectrum: corrected_spectrum,
        turbidity: turbidity
      }

      {:ok, result}
    end
  end

  @doc """
  Measures protein concentration using A280.

  Returns A280, estimated concentration, and the full spectrum.

  ## Options

  - `:extinction_coefficient` - Extinction coefficient (default: 1.0, meaning 1 A280 = 1 mg/mL)

  Requires calibration.
  """
  def measure_protein(server, opts \\ []) do
    with {:ok, spectrum} <- get_spectrum(server) do
      a280 = absorbance_at(spectrum, 280.0)

      extinction = Keyword.get(opts, :extinction_coefficient, 1.0)

      result = %{
        a280: a280,
        concentration_mg_ml: a280 / extinction,
        spectrum: spectrum
      }

      {:ok, result}
    end
  end

  # ===========================================================================
  # Helper Functions
  # ===========================================================================

  defp initialize_device(device) do
    with :ok <- OOI.initialize(device),
         :ok <- OOI.set_integration_time(device, @default_integration_time),
         {:ok, serial} <- OOI.query_info(device, :serial_number),
         {:ok, calibration} <- OOI.query_info(device, :wavelength_calibration) do
      state = %__MODULE__{
        device: device,
        serial_number: serial,
        wavelength_calibration: calibration,
        integration_time: @default_integration_time,
        dark: nil,
        blank: nil
      }

      {:ok, state}
    end
  end

  defp _calibrated?(%{dark: nil}, _now), do: false
  defp _calibrated?(%{blank: nil}, _now), do: false

  defp _calibrated?(state, now) do
    calibrated_at = Enum.min([state.dark.timestamp, state.blank.timestamp], DateTime)

    calibration_age = DateTime.diff(now, calibrated_at, :second)
    calibration_stale = calibration_age > @calibration_max_age_seconds

    measurement_stale =
      state.last_measurement_at == nil or
        DateTime.diff(now, state.last_measurement_at, :second) > @measurement_staleness_seconds

    not (calibration_stale and measurement_stale)
  end

  defp check_calibration(%{dark: nil}, _now), do: {:error, :no_dark_calibration}
  defp check_calibration(%{blank: nil}, _now), do: {:error, :no_blank_calibration}

  defp check_calibration(state, now) do
    if _calibrated?(state, now) do
      :ok
    else
      {:error, :recalibration_needed}
    end
  end

  defp calculate_absorbance_spectrum(sample, state) do
    dark = state.dark.raw_pixels
    blank = state.blank.raw_pixels
    sample_pixels = sample.raw_pixels
    cal = state.wavelength_calibration

    absorbance =
      [sample_pixels, dark, blank]
      |> Enum.zip()
      |> Enum.map(fn {s, d, b} ->
        transmittance = (s - d) / max(b - d, 1)
        -:math.log10(max(transmittance, 0.0001))
      end)

    wavelengths =
      Enum.map(0..2047, fn n ->
        cal.intercept +
          cal.first_coefficient * n +
          cal.second_coefficient * n * n +
          cal.third_coefficient * n * n * n
      end)

    Spectrum.new(wavelengths, absorbance)
  end

  defp safe_ratio(_a, b) when b == 0, do: nil
  defp safe_ratio(a, b), do: a / b

  # ===========================================================================
  # Router
  # ===========================================================================

  @impl true
  def handle_call(:info, from, state), do: info_impl(from, state)
  def handle_call(:serial_number, from, state), do: serial_number_impl(from, state)

  def handle_call(:wavelength_calibration, from, state),
    do: wavelength_calibration_impl(from, state)

  def handle_call({:set_integration_time, us}, from, state),
    do: set_integration_time_impl(us, from, state)

  def handle_call({:set_spectrum, mode}, from, state), do: set_spectrum_impl(mode, from, state)
  def handle_call(:calibrate, from, state), do: calibrate_impl(from, state)
  def handle_call(:calibrated?, from, state), do: calibrated_impl(from, state)
  def handle_call(:get_raw_spectrum, from, state), do: get_raw_spectrum_impl(from, state)
  def handle_call(:get_spectrum, from, state), do: get_spectrum_impl(from, state)
end
