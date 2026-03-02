defmodule Nanodrop.USB do
  @moduledoc """
  Behaviour for USB operations.

  This module defines callbacks for USB communication and provides a default
  implementation using the `usb` library. In tests, this can be replaced with
  a mock using Mox.
  """

  @type device :: reference()
  @type device_handle :: reference()
  @type device_descriptor :: %{
          vendor_id: non_neg_integer(),
          product_id: non_neg_integer()
        }

  @callback get_device_list() :: {:ok, [device()]} | {:error, term()}
  @callback get_device_descriptor(device()) :: {:ok, device_descriptor()} | {:error, term()}
  @callback get_bus_number(device()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback get_device_address(device()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback open_device(device()) :: {:ok, device_handle()} | {:error, term()}
  @callback close_device(device_handle()) :: :ok | {:error, term()}
  @callback claim_interface(device_handle(), non_neg_integer()) :: :ok | {:error, term()}
  @callback write_bulk(device_handle(), byte(), binary(), timeout()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback read_bulk(device_handle(), byte(), non_neg_integer(), timeout()) ::
              {:ok, binary()} | {:error, term()}
end
