import Config

if config_env() == :test do
  config :nanodrop, :usb, Nanodrop.USB.Mock
end
