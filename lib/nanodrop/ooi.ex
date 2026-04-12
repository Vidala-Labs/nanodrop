defmodule Nanodrop.OOI do
  @moduledoc """
  Ocean Optics Interface (OOI) protocol implementation.

  This module implements the USB2000 command protocol for communicating
  with NanoDrop spectrophotometers and defines the raw spectrum data structure.

  ## Command Reference

  | Command | Hex  | Description |
  |---------|------|-------------|
  | Initialize | 0x01 | Initialize spectrometer |
  | Set Integration Time | 0x02 | Set integration time in µs |
  | Set Strobe Enable | 0x03 | Enable/disable strobe |
  | Set Shutdown Mode | 0x04 | Enter low-power mode |
  | Query Information | 0x05 | Query device info/calibration |
  | Write Information | 0x06 | Write configuration |
  | Request Spectra | 0x09 | Trigger spectrum acquisition |
  | Set Trigger Mode | 0x0A | Set triggering mode |

  ## Raw Spectrum Data

  The USB2000 returns 2048 pixel values representing light intensity across
  the detector. The wavelength for each pixel is calculated using calibration
  coefficients stored on the device:

      λ(N) = C0 + C1*N + C2*N² + C3*N³

  Pixels 2-24 are "dark pixels" - optically masked for dark current subtraction.
  """

  alias Nanodrop.Device

  # OOI Protocol Commands
  @cmd_initialize 0x01
  @cmd_set_integration_time 0x02
  @cmd_set_strobe_enable 0x03
  @cmd_query_info 0x05
  @cmd_request_spectra 0x09
  @cmd_set_trigger_mode 0x0A

  # Query information slots
  @query_serial_number 0x00
  @query_wavelength_coeff_0 0x01
  @query_wavelength_coeff_1 0x02
  @query_wavelength_coeff_2 0x03
  @query_wavelength_coeff_3 0x04
  @query_config 0x0F

  # USB2000 specifications
  @num_pixels 2048
  @dark_pixel_start 2
  @dark_pixel_end 24
  @min_integration_time 3_000
  @max_integration_time 655_350_000

  # ===========================================================================
  # Struct Definition - Raw spectrum data from the device
  # ===========================================================================

  @type t :: %__MODULE__{
          raw_pixels: [non_neg_integer()],
          timestamp: DateTime.t()
        }

  defstruct raw_pixels: [],
            timestamp: nil

  @doc """
  Creates an OOI struct from raw binary data.

  The data should be 4096 bytes (2048 x 16-bit little-endian values).
  """
  @spec from_raw(binary()) :: t()
  def from_raw(data) when byte_size(data) >= @num_pixels * 2 do
    %__MODULE__{
      raw_pixels: decode_pixels(data),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Returns the dark pixel values (pixels 2-24).
  """
  @spec dark_pixels(t()) :: [non_neg_integer()]
  def dark_pixels(%__MODULE__{raw_pixels: pixels}) do
    Enum.slice(pixels, @dark_pixel_start, @dark_pixel_end - @dark_pixel_start + 1)
  end

  @doc """
  Calculates the average dark pixel value.
  """
  @spec dark_average(t()) :: float()
  def dark_average(%__MODULE__{} = ooi) do
    dark = dark_pixels(ooi)
    Enum.sum(dark) / length(dark)
  end

  @doc """
  Returns the maximum pixel intensity.
  """
  @spec max_intensity(t()) :: non_neg_integer()
  def max_intensity(%__MODULE__{raw_pixels: pixels}) do
    Enum.max(pixels)
  end

  # ===========================================================================
  # Protocol Commands
  # ===========================================================================

  @doc """
  Initializes the spectrometer.
  """
  @spec initialize(Device.t()) :: :ok | {:error, term()}
  def initialize(device) do
    Device.send_command(device, <<@cmd_initialize>>)
  end

  @doc """
  Sets the integration time in microseconds.

  Valid range: 3,000 - 655,350,000 µs
  """
  @spec set_integration_time(Device.t(), pos_integer()) :: :ok | {:error, term()}
  def set_integration_time(device, microseconds)
      when microseconds >= @min_integration_time and microseconds <= @max_integration_time do
    ms = div(microseconds, 1000)
    Device.send_command(device, <<@cmd_set_integration_time, ms::little-16>>)
  end

  def set_integration_time(_device, microseconds) do
    {:error,
     {:invalid_integration_time, microseconds,
      min: @min_integration_time, max: @max_integration_time}}
  end

  @doc """
  Acquires a spectrum from the device with the lamp/strobe firing.
  Use this for blank and sample measurements.
  """
  @spec get_spectrum(Device.t()) :: {:ok, t()} | {:error, term()}
  def get_spectrum(device) do
    with :ok <- set_strobe_enable(device, true),
         :ok <- strobe_warmup(),
         :ok <- Device.send_command(device, <<@cmd_request_spectra>>),
         {:ok, data} <- read_spectrum_data(device),
         :ok <- set_strobe_enable(device, false) do
      {:ok, from_raw(data)}
    end
  end

  defp strobe_warmup do
    Process.sleep(100)
    :ok
  end

  @doc """
  Acquires a dark spectrum (no lamp/strobe).
  Use this for dark calibration to measure detector baseline.
  """
  @spec get_dark_spectrum(Device.t()) :: {:ok, t()} | {:error, term()}
  def get_dark_spectrum(device) do
    with :ok <- set_strobe_enable(device, false),
         :ok <- Device.send_command(device, <<@cmd_request_spectra>>),
         {:ok, data} <- read_spectrum_data(device) do
      {:ok, from_raw(data)}
    end
  end

  @doc """
  Queries device information.
  """
  @spec query_info(Device.t(), atom()) :: {:ok, term()} | {:error, term()}
  def query_info(device, :serial_number) do
    query_slot(device, @query_serial_number)
  end

  def query_info(device, :wavelength_calibration) do
    with {:ok, c0} <- query_slot(device, @query_wavelength_coeff_0),
         {:ok, c1} <- query_slot(device, @query_wavelength_coeff_1),
         {:ok, c2} <- query_slot(device, @query_wavelength_coeff_2),
         {:ok, c3} <- query_slot(device, @query_wavelength_coeff_3) do
      {:ok,
       %{
         intercept: parse_float(c0),
         first_coefficient: parse_float(c1),
         second_coefficient: parse_float(c2),
         third_coefficient: parse_float(c3)
       }}
    end
  end

  def query_info(device, :config) do
    query_slot(device, @query_config)
  end

  def query_info(_device, query_type) do
    {:error, {:unknown_query_type, query_type}}
  end

  @doc """
  Sets the trigger mode.

  Modes:
  - 0: Normal (free running)
  - 1: Software trigger
  - 2: External hardware level trigger
  - 3: External synchronization trigger
  """
  @spec set_trigger_mode(Device.t(), 0..3) :: :ok | {:error, term()}
  def set_trigger_mode(device, mode) when mode in 0..3 do
    Device.send_command(device, <<@cmd_set_trigger_mode, mode::8>>)
  end

  @doc """
  Enables or disables the strobe.
  """
  @spec set_strobe_enable(Device.t(), boolean()) :: :ok | {:error, term()}
  def set_strobe_enable(device, enabled) do
    value = if enabled, do: 1, else: 0
    Device.send_command(device, <<@cmd_set_strobe_enable, value::8>>)
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp query_slot(device, slot) do
    with :ok <- Device.send_command(device, <<@cmd_query_info, slot::8>>),
         {:ok, response} <- Device.read_query(device, 64) do
      case response do
        <<@cmd_query_info, ^slot, rest::binary>> ->
          {:ok, extract_string(rest)}

        _ ->
          {:error, :invalid_response}
      end
    end
  end

  defp read_spectrum_data(device) do
    read_all_packets(device, [])
  end

  defp read_all_packets(device, acc) do
    case Device.read_spectrum(device, 64) do
      {:ok, <<0x69>>} ->
        reorder_usb2000_bytes(Enum.reverse(acc))

      {:ok, data} when byte_size(data) > 0 ->
        read_all_packets(device, [data | acc])

      {:ok, <<>>} ->
        read_all_packets(device, acc)

      {:error, :timeout, _} when acc != [] ->
        reorder_usb2000_bytes(Enum.reverse(acc))

      {:error, :timeout} when acc != [] ->
        reorder_usb2000_bytes(Enum.reverse(acc))

      {:error, reason, _} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reorder_usb2000_bytes(packets) do
    raw_data = IO.iodata_to_binary(packets)
    raw_bytes = :binary.bin_to_list(raw_data)
    n_raw = length(raw_bytes)

    reordered =
      0..(n_raw - 1)
      |> Enum.map(fn i ->
        new_idx = rem(div(i, 2), 64) + rem(i, 2) * 64 + div(i, 128) * 128
        Enum.at(raw_bytes, new_idx, 0)
      end)
      |> :binary.list_to_bin()

    {:ok, reordered}
  end

  defp decode_pixels(data), do: decode_pixels(data, [])

  defp decode_pixels(<<value::little-16, rest::binary>>, acc) do
    decode_pixels(rest, [value | acc])
  end

  defp decode_pixels(<<>>, acc), do: Enum.reverse(acc)
  defp decode_pixels(_, acc), do: Enum.reverse(acc)

  defp extract_string(binary) do
    binary
    |> :binary.split(<<0>>)
    |> List.first()
    |> String.trim()
  end

  defp parse_float(string) do
    case Float.parse(string) do
      {value, _} -> value
      :error -> 0.0
    end
  end
end
