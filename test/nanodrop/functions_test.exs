defmodule Nanodrop.FunctionsTest do
  use ExUnit.Case

  alias Nanodrop.Functions.Gaussian
  alias Nanodrop.Functions.Turbidity

  describe "Gaussian" do
    test "evaluate returns peak value at center" do
      gaussian = %Gaussian{amplitude: 1.0, center: 260.0, sigma: 30.0}

      # At center, exp(0) = 1, so result = amplitude
      assert Gaussian.evaluate(gaussian, 260.0) == 1.0
    end

    test "evaluate returns lower values away from center" do
      gaussian = %Gaussian{amplitude: 1.0, center: 260.0, sigma: 30.0}

      at_center = Gaussian.evaluate(gaussian, 260.0)
      off_center = Gaussian.evaluate(gaussian, 290.0)

      assert off_center < at_center
    end

    test "evaluate_all returns values for all wavelengths" do
      gaussian = %Gaussian{amplitude: 0.5, center: 260.0, sigma: 30.0}
      wavelengths = [250.0, 260.0, 270.0]

      values = Gaussian.evaluate_all(gaussian, wavelengths)

      assert length(values) == 3
      # Center should have highest value
      assert Enum.at(values, 1) > Enum.at(values, 0)
      assert Enum.at(values, 1) > Enum.at(values, 2)
    end

    test "Access behaviour - fetch" do
      gaussian = %Gaussian{amplitude: 0.5, center: 260.0, sigma: 30.0}

      assert gaussian[:amplitude] == 0.5
      assert gaussian[:center] == 260.0
      assert gaussian[:sigma] == 30.0
      assert gaussian[:invalid] == nil
    end

    test "Access behaviour - get_and_update" do
      gaussian = %Gaussian{amplitude: 0.5, center: 260.0, sigma: 30.0}

      {old, new} = Access.get_and_update(gaussian, :amplitude, fn v -> {v, v * 2} end)

      assert old == 0.5
      assert new.amplitude == 1.0
    end
  end

  describe "Turbidity" do
    test "evaluate returns expected scattering curve" do
      turbidity = %Turbidity{a: 1000.0, n: 2.0, b: 0.1}

      # a * λ^(-n) + b = 1000 * 100^(-2) + 0.1 = 1000 * 0.0001 + 0.1 = 0.2
      result = Turbidity.evaluate(turbidity, 100.0)
      assert_in_delta result, 0.2, 0.001
    end

    test "evaluate shows decreasing scattering with wavelength" do
      turbidity = %Turbidity{a: 1000.0, n: 2.0, b: 0.0}

      short_wl = Turbidity.evaluate(turbidity, 220.0)
      long_wl = Turbidity.evaluate(turbidity, 400.0)

      # Scattering decreases with wavelength (λ^-n)
      assert short_wl > long_wl
    end

    test "evaluate_all returns values for all wavelengths" do
      turbidity = %Turbidity{a: 1000.0, n: 2.0, b: 0.1}
      wavelengths = [220.0, 260.0, 400.0]

      values = Turbidity.evaluate_all(turbidity, wavelengths)

      assert length(values) == 3
      # Scattering decreases with wavelength
      assert Enum.at(values, 0) > Enum.at(values, 1)
      assert Enum.at(values, 1) > Enum.at(values, 2)
    end

    test "Access behaviour - fetch" do
      turbidity = %Turbidity{a: 1000.0, n: 2.0, b: 0.1}

      assert turbidity[:a] == 1000.0
      assert turbidity[:n] == 2.0
      assert turbidity[:b] == 0.1
      assert turbidity[:invalid] == nil
    end

    test "Access behaviour - get_and_update" do
      turbidity = %Turbidity{a: 1000.0, n: 2.0, b: 0.1}

      {old, new} = Access.get_and_update(turbidity, :n, fn v -> {v, v + 1} end)

      assert old == 2.0
      assert new.n == 3.0
    end
  end
end
