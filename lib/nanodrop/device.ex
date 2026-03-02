defmodule Nanodrop.Device do
  @moduledoc """
  USB device management for NanoDrop spectrophotometers.

  Handles device enumeration, connection, and low-level USB communication
  using the Ocean Optics USB2000 endpoints.
  """

  @usb Application.compile_env(:nanodrop, :usb, :usb)

  @vendor_id 0x2457
  @product_id 0x1002

  # USB2000 endpoint addresses
  @ep_out 0x02
  @ep_in_spectrum 0x82
  @ep_in_query 0x87

  @timeout_ms 1000

  @type device_info :: %{
          vendor_id: non_neg_integer(),
          product_id: non_neg_integer(),
          bus: non_neg_integer(),
          address: non_neg_integer(),
          device_ref: reference()
        }

  @type t :: %__MODULE__{
          handle: reference(),
          device_info: device_info()
        }

  defstruct [:handle, :device_info]

  @doc """
  Lists all connected NanoDrop/USB2000 devices.
  """
  @spec list_devices() :: [device_info()]
  def list_devices do
    case @usb.get_device_list() do
      {:ok, devices} ->
        for device <- devices, nanodrop_device?(device), do: device_to_info(device)

      {:error, _} ->
        []
    end
  end

  @doc """
  Opens a connection to a NanoDrop device.
  """
  @spec open(device_info() | nil) :: {:ok, t()} | {:error, term()}
  def open(device_info \\ nil)

  def open(nil) do
    case list_devices() do
      [] -> {:error, :no_device_found}
      [first | _] -> open(first)
    end
  end

  def open(%{device_ref: device_ref} = device_info) do
    with {:ok, handle} <- @usb.open_device(device_ref),
         :ok <- claim_interface(handle) do
      {:ok, %__MODULE__{handle: handle, device_info: device_info}}
    end
  end

  @doc """
  Closes a device connection.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{handle: handle}) do
    @usb.close_device(handle)
    :ok
  end

  @doc """
  Sends a command to the device (bulk transfer out).
  """
  @spec send_command(t(), binary()) :: :ok | {:error, term()}
  def send_command(%__MODULE__{handle: handle}, data) when is_binary(data) do
    case @usb.write_bulk(handle, @ep_out, data, @timeout_ms) do
      {:ok, _bytes_sent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads spectrum data from the device (bulk transfer in on EP 0x82).
  """
  @spec read_spectrum(t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def read_spectrum(%__MODULE__{handle: handle}, length \\ 4096) do
    @usb.read_bulk(handle, @ep_in_spectrum, length, @timeout_ms)
  end

  @doc """
  Reads query response from the device (bulk transfer in on EP 0x87).
  """
  @spec read_query(t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def read_query(%__MODULE__{handle: handle}, length \\ 64) do
    @usb.read_bulk(handle, @ep_in_query, length, @timeout_ms)
  end

  # Private functions

  defp nanodrop_device?(device) do
    case @usb.get_device_descriptor(device) do
      {:ok, %{vendor_id: @vendor_id, product_id: @product_id}} -> true
      _ -> false
    end
  end

  defp device_to_info(device) do
    {:ok, desc} = @usb.get_device_descriptor(device)
    {:ok, bus} = @usb.get_bus_number(device)
    {:ok, address} = @usb.get_device_address(device)

    %{
      vendor_id: desc.vendor_id,
      product_id: desc.product_id,
      bus: bus,
      address: address,
      device_ref: device
    }
  end

  defp claim_interface(handle) do
    case @usb.claim_interface(handle, 0) do
      :ok -> :ok
      {:error, reason} -> {:error, {:claim_interface, reason}}
    end
  end
end
