defmodule Wallaby.HTTPClient do
  @moduledoc false

  alias Wallaby.Query

  @type method :: :post | :get | :delete
  @type url :: String.t()
  @type params :: map | String.t()
  @type request_opts :: {:encode_json, boolean}
  @type response :: map
  @type web_driver_error_reason :: :stale_reference | :invalid_selector | :unexpected_alert

  @status_obscured 13
  # The maximum time we'll sleep is for 50ms
  @max_jitter 50

  @doc """
  Sends a request to the webdriver API and parses the
  response.
  """
  @spec request(method, url, params, [request_opts]) ::
          {:ok, response}
          | {:error, web_driver_error_reason | Jason.DecodeError.t() | String.t()}
          | no_return

  def request(method, url, params \\ %{}, opts \\ [], headers \\ default_headers())

  def request(method, url, params, _opts, headers) when map_size(params) == 0 do
    make_request(method, url, "", headers)
  end

  def request(method, url, params, [{:encode_json, false} | _], headers) do
    make_request(method, url, params, headers)
  end

  def request(method, url, params, _opts, headers) do
    make_request(method, url, Jason.encode!(params), headers)
  end

  defp make_request(method, url, body, headers), do: make_request(method, url, body, headers, 0, [])

  @spec make_request(method, url, String.t() | map, List.t(), non_neg_integer(), [String.t()]) ::
          {:ok, response}
          | {:error, web_driver_error_reason | Jason.DecodeError.t() | String.t()}
          | no_return
  defp make_request(_, _, _, _, 5, retry_reasons) do
    ["Wallaby had an internal issue with HTTPoison:" | retry_reasons]
    |> Enum.uniq()
    |> Enum.join("\n")
    |> raise
  end

  defp make_request(method, url, body, headers, retry_count, retry_reasons) do
    method
    |> HTTPoison.request(url, body, headers, request_opts())
    |> handle_response
    |> case do
      {:error, :httpoison, error} ->
        :timer.sleep(jitter())
        make_request(method, url, body, headers, retry_count + 1, [inspect(error) | retry_reasons])

      result ->
        result
    end
  end

  @spec handle_response({:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}) ::
          {:ok, response}
          | {:error, web_driver_error_reason | Jason.DecodeError.t() | String.t()}
          | {:error, :httpoison, HTTPoison.Error.t()}
          | no_return
  defp handle_response(resp) do
    case resp do
      {:error, %HTTPoison.Error{} = error} ->
        {:error, :httpoison, error}

      {:ok, %HTTPoison.Response{status_code: 204}} ->
        {:ok, %{"value" => nil}}

      {:ok, %HTTPoison.Response{body: body}} ->
        with {:ok, decoded} <- Jason.decode(body),
             {:ok, response} <- check_status(decoded),
             {:ok, validated} <- check_for_response_errors(response),
             do: {:ok, validated}
    end
  end

  @spec check_status(response) :: {:ok, response} | {:error, String.t()}
  defp check_status(response) do
    case Map.get(response, "status") do
      @status_obscured ->
        message = get_in(response, ["value", "message"])

        {:error, message}

      _ ->
        {:ok, response}
    end
  end

  @spec check_for_response_errors(response) ::
          {:ok, response}
          | {:error, web_driver_error_reason}
          | no_return
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp check_for_response_errors(response) do
    case Map.get(response, "value") do
      %{"class" => "org.openqa.selenium.StaleElementReferenceException"} ->
        {:error, :stale_reference}

      %{"message" => "Stale element reference" <> _} ->
        {:error, :stale_reference}

      %{"message" => "stale element reference" <> _} ->
        {:error, :stale_reference}

      %{
        "message" =>
          "An element command failed because the referenced element is no longer available" <> _
      } ->
        {:error, :stale_reference}

      %{"message" => "invalid selector" <> _} ->
        {:error, :invalid_selector}

      %{"class" => "org.openqa.selenium.InvalidSelectorException"} ->
        {:error, :invalid_selector}

      %{"class" => "org.openqa.selenium.InvalidElementStateException"} ->
        {:error, :invalid_selector}

      %{"message" => "unexpected alert" <> _} ->
        {:error, :unexpected_alert}

      %{"error" => _, "message" => message} ->
        raise message

      _ ->
        {:ok, response}
    end
  end

  defp request_opts do
    Application.get_env(:wallaby, :hackney_options, hackney: [pool: :wallaby_pool])
  end

  def default_headers do
    [{"Accept", "application/json"}, {"Content-Type", "application/json"}]
  end

  def default_headers_map do
    Enum.reduce(default_headers(), %{}, fn {key, value}, headers_map ->
      Map.put(headers_map, key, value)
    end)
  end

  @spec to_params(Query.compiled()) :: map
  def to_params({:xpath, xpath}) do
    %{using: "xpath", value: xpath}
  end

  def to_params({:css, css}) do
    %{using: "css selector", value: css}
  end

  defp jitter, do: :rand.uniform(@max_jitter)
end
