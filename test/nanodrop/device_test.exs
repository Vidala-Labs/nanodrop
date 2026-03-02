defmodule Nanodrop.DeviceTest do
  use ExUnit.Case, async: true

  import Mox

  alias Nanodrop.Device

  setup :verify_on_exit!

  @vendor_id 0x2457
  @product_id 0x1002

  describe "list_devices/0" do
    test "returns empty list when no devices connected" do
      expect(Nanodrop.USB.Mock, :get_device_list, fn -> {:ok, []} end)

      assert Device.list_devices() == []
    end

    test "returns empty list on USB error" do
      expect(Nanodrop.USB.Mock, :get_device_list, fn -> {:error, :no_context} end)

      assert Device.list_devices() == []
    end

    test "filters to only NanoDrop devices" do
      device1 = make_ref()
      device2 = make_ref()
      device3 = make_ref()

      expect(Nanodrop.USB.Mock, :get_device_list, fn -> {:ok, [device1, device2, device3]} end)

      # Use stub for get_device_descriptor since it's called multiple times per device
      stub(Nanodrop.USB.Mock, :get_device_descriptor, fn
        ^device1 -> {:ok, %{vendor_id: @vendor_id, product_id: @product_id}}
        ^device2 -> {:ok, %{vendor_id: 0x1234, product_id: 0x5678}}
        ^device3 -> {:ok, %{vendor_id: @vendor_id, product_id: @product_id}}
      end)

      stub(Nanodrop.USB.Mock, :get_bus_number, fn
        ^device1 -> {:ok, 1}
        ^device3 -> {:ok, 2}
      end)

      stub(Nanodrop.USB.Mock, :get_device_address, fn
        ^device1 -> {:ok, 10}
        ^device3 -> {:ok, 20}
      end)

      devices = Device.list_devices()

      assert length(devices) == 2
      assert Enum.all?(devices, &(&1.vendor_id == @vendor_id))
      assert Enum.all?(devices, &(&1.product_id == @product_id))
    end

    test "includes bus and address in device info" do
      device = make_ref()

      Nanodrop.USB.Mock
      |> expect(:get_device_list, fn -> {:ok, [device]} end)
      |> expect(:get_device_descriptor, fn ^device ->
        {:ok, %{vendor_id: @vendor_id, product_id: @product_id}}
      end)
      |> expect(:get_bus_number, fn ^device -> {:ok, 1} end)
      |> expect(:get_device_address, fn ^device -> {:ok, 19} end)
      |> expect(:get_device_descriptor, fn ^device ->
        {:ok, %{vendor_id: @vendor_id, product_id: @product_id}}
      end)

      [info] = Device.list_devices()

      assert info.bus == 1
      assert info.address == 19
      assert info.device_ref == device
    end
  end

  describe "open/1" do
    test "opens first available device when called with nil" do
      device_ref = make_ref()
      handle = make_ref()

      Nanodrop.USB.Mock
      |> expect(:get_device_list, fn -> {:ok, [device_ref]} end)
      |> expect(:get_device_descriptor, fn ^device_ref ->
        {:ok, %{vendor_id: @vendor_id, product_id: @product_id}}
      end)
      |> expect(:get_bus_number, fn ^device_ref -> {:ok, 1} end)
      |> expect(:get_device_address, fn ^device_ref -> {:ok, 19} end)
      |> expect(:get_device_descriptor, fn ^device_ref ->
        {:ok, %{vendor_id: @vendor_id, product_id: @product_id}}
      end)
      |> expect(:open_device, fn ^device_ref -> {:ok, handle} end)
      |> expect(:claim_interface, fn ^handle, 0 -> :ok end)

      assert {:ok, %Device{handle: ^handle}} = Device.open(nil)
    end

    test "returns error when no device found" do
      expect(Nanodrop.USB.Mock, :get_device_list, fn -> {:ok, []} end)

      assert {:error, :no_device_found} = Device.open(nil)
    end

    test "opens specific device by device_info" do
      device_ref = make_ref()
      handle = make_ref()

      device_info = %{
        vendor_id: @vendor_id,
        product_id: @product_id,
        bus: 1,
        address: 19,
        device_ref: device_ref
      }

      Nanodrop.USB.Mock
      |> expect(:open_device, fn ^device_ref -> {:ok, handle} end)
      |> expect(:claim_interface, fn ^handle, 0 -> :ok end)

      assert {:ok, %Device{handle: ^handle, device_info: ^device_info}} = Device.open(device_info)
    end

    test "returns error when claim_interface fails" do
      device_ref = make_ref()
      handle = make_ref()

      device_info = %{
        vendor_id: @vendor_id,
        product_id: @product_id,
        bus: 1,
        address: 19,
        device_ref: device_ref
      }

      Nanodrop.USB.Mock
      |> expect(:open_device, fn ^device_ref -> {:ok, handle} end)
      |> expect(:claim_interface, fn ^handle, 0 -> {:error, :busy} end)

      assert {:error, {:claim_interface, :busy}} = Device.open(device_info)
    end
  end

  describe "close/1" do
    test "closes the device handle" do
      handle = make_ref()
      device = %Device{handle: handle, device_info: %{}}

      expect(Nanodrop.USB.Mock, :close_device, fn ^handle -> :ok end)

      assert :ok = Device.close(device)
    end
  end

  describe "send_command/2" do
    test "sends binary data to EP2 OUT" do
      handle = make_ref()
      device = %Device{handle: handle, device_info: %{}}
      command = <<0x01>>

      expect(Nanodrop.USB.Mock, :write_bulk, fn ^handle, 0x02, ^command, 1000 ->
        {:ok, 1}
      end)

      assert :ok = Device.send_command(device, command)
    end

    test "returns error on write failure" do
      handle = make_ref()
      device = %Device{handle: handle, device_info: %{}}

      expect(Nanodrop.USB.Mock, :write_bulk, fn _handle, _ep, _data, _timeout ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Device.send_command(device, <<0x01>>)
    end
  end

  describe "read_spectrum/2" do
    test "reads from EP 0x82" do
      handle = make_ref()
      device = %Device{handle: handle, device_info: %{}}
      data = :binary.copy(<<0x00>>, 512)

      expect(Nanodrop.USB.Mock, :read_bulk, fn ^handle, 0x82, 4096, 1000 ->
        {:ok, data}
      end)

      assert {:ok, ^data} = Device.read_spectrum(device)
    end
  end

  describe "read_query/2" do
    test "reads from EP 0x87" do
      handle = make_ref()
      device = %Device{handle: handle, device_info: %{}}
      response = <<0x05, 0x00, "USB2000", 0x00>>

      expect(Nanodrop.USB.Mock, :read_bulk, fn ^handle, 0x87, 64, 1000 ->
        {:ok, response}
      end)

      assert {:ok, ^response} = Device.read_query(device)
    end
  end
end
