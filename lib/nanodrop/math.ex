defmodule Nanodrop.Math do
  @moduledoc """
  Mathematical utilities for curve fitting.

  Provides Levenberg-Marquardt nonlinear least squares optimization.
  """

  @doc """
  Levenberg-Marquardt nonlinear least squares optimization.

  Fits parameters to minimize the sum of squared residuals between
  the model predictions and observed data.

  ## Parameters

  - `x` - Independent variable values (list of floats)
  - `y` - Observed dependent variable values (list of floats)
  - `model_fn` - Function `(x, params) -> y_predicted` where params is a list
  - `jacobian_fn` - Function `(x, params) -> [dy/dp1, dy/dp2, ...]` partial derivatives
  - `initial_params` - Initial parameter guesses (list of floats)
  - `opts` - Options:
    - `:max_iterations` - Maximum iterations (default: 100)
    - `:tolerance` - Convergence tolerance for parameter change (default: 1.0e-8)
    - `:lambda` - Initial damping factor (default: 0.001)

  ## Returns

  `{:ok, %{params: [...], iterations: n, final_error: e}}` on success,
  `{:error, reason}` on failure.

  ## Example

      # Fit y = a * x + b
      model = fn x, [a, b] -> a * x + b end
      jacobian = fn x, [_a, _b] -> [x, 1.0] end

      {:ok, result} = Nanodrop.Math.levenberg_marquardt(
        x_data, y_data, model, jacobian, [1.0, 0.0]
      )
  """
  @spec levenberg_marquardt(
          [float()],
          [float()],
          (float(), [float()] -> float()),
          (float(), [float()] -> [float()]),
          [float()],
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def levenberg_marquardt(x, y, model_fn, jacobian_fn, initial_params, opts \\ []) do
    max_iter = Keyword.get(opts, :max_iterations, 100)
    tol = Keyword.get(opts, :tolerance, 1.0e-8)
    lambda = Keyword.get(opts, :lambda, 0.001)

    x_tensor = Nx.tensor(x, type: :f64)
    y_tensor = Nx.tensor(y, type: :f64)
    params = initial_params

    iterate(x_tensor, y_tensor, x, y, model_fn, jacobian_fn, params, lambda, 0, max_iter, tol)
  end

  defp iterate(_x_t, _y_t, _x, _y, _model_fn, _jacobian_fn, params, _lambda, iter, max_iter, _tol)
       when iter >= max_iter do
    {:ok, %{params: params, iterations: iter, converged: false}}
  end

  defp iterate(x_tensor, y_tensor, x, y, model_fn, jacobian_fn, params, lambda, iter, max_iter, tol) do
    p = length(params)

    # Compute residuals: r = y - f(x, params)
    predictions = Enum.map(x, fn xi -> model_fn.(xi, params) end)
    residuals = Nx.subtract(y_tensor, Nx.tensor(predictions, type: :f64))

    current_error = residuals |> Nx.pow(2) |> Nx.sum() |> Nx.to_number()

    # Compute Jacobian matrix (n x p)
    jacobian_rows = Enum.map(x, fn xi -> jacobian_fn.(xi, params) end)
    j = Nx.tensor(jacobian_rows, type: :f64)

    # J^T * J
    jt = Nx.transpose(j)
    jtj = Nx.dot(jt, j)

    # J^T * r
    jtr = Nx.dot(jt, residuals)

    # (J^T*J + lambda*I) * delta = J^T * r
    # Add lambda to diagonal
    diag_addition = Nx.multiply(Nx.eye(p, type: :f64), lambda)
    lhs = Nx.add(jtj, diag_addition)

    # Solve for delta
    case safe_solve(lhs, jtr) do
      {:ok, delta} ->
        delta_list = Nx.to_flat_list(delta)
        new_params = Enum.zip_with(params, delta_list, fn p, d -> p + d end)

        # Check if new params reduce error
        new_predictions = Enum.map(x, fn xi -> model_fn.(xi, new_params) end)
        new_residuals = Nx.subtract(y_tensor, Nx.tensor(new_predictions, type: :f64))
        new_error = new_residuals |> Nx.pow(2) |> Nx.sum() |> Nx.to_number()

        # Compute parameter change magnitude
        param_change =
          delta_list
          |> Enum.map(&abs/1)
          |> Enum.max()

        cond do
          param_change < tol ->
            # Converged
            {:ok, %{params: new_params, iterations: iter + 1, final_error: new_error, converged: true}}

          new_error < current_error ->
            # Accept step, decrease lambda
            iterate(x_tensor, y_tensor, x, y, model_fn, jacobian_fn, new_params, lambda * 0.1, iter + 1, max_iter, tol)

          true ->
            # Reject step, increase lambda and retry
            iterate(x_tensor, y_tensor, x, y, model_fn, jacobian_fn, params, lambda * 10, iter + 1, max_iter, tol)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_solve(a, b) do
    try do
      # Reshape b to be a column vector for solve
      b_col = Nx.reshape(b, {Nx.axis_size(b, 0), 1})
      result = Nx.LinAlg.solve(a, b_col)
      {:ok, Nx.flatten(result)}
    rescue
      e -> {:error, e}
    end
  end
end
