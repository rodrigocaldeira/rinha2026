defmodule Rinha2026.Handler do
  def init(req, _opts) do
    path = :cowboy_req.path(req)

    case path do
      "/ready" ->
        req = :cowboy_req.reply(200, %{"content-type" => "text/plain"}, "OK", req)
        {:ok, req, nil}

      "/fraud-score" ->
        {:ok, body, req} = :cowboy_req.read_body(req)
        tx = :json.decode(body)

        score =
          cond do
            pure_legit?(tx) ->
              0.0

            pure_fraud?(tx) ->
              1.0

            risky_borderline_fraud?(tx) ->
              1.0

            true ->
              tx
              |> Rinha2026.Vectorizer.vectorize()
              |> Rinha2026.NIF.knn()
          end

        result =
          if score < 0.6 do
            ~s[{"approved": true, "fraud_score": #{score}}]
          else
            ~s[{"approved": false, "fraud_score": #{score}}]
          end

        req = :cowboy_req.reply(200, %{"content-type" => "application/json"}, result, req)
        {:ok, req, nil}

      _ ->
        req = :cowboy_req.reply(404, %{"content-type" => "text/plain"}, "Not Found", req)
        {:ok, req, nil}
    end
  end

  defp pure_legit?(%{
         "transaction" => %{
           "amount" => amount,
           "installments" => installments,
           "requested_at" => requested_at
         },
         "customer" => %{
           "avg_amount" => avg_amount,
           "tx_count_24h" => tx_count_24h,
           "known_merchants" => known_merchants
         },
         "merchant" => %{
           "id" => merchant_id,
           "mcc" => mcc,
           "avg_amount" => merchant_avg_amount
         },
         "terminal" => %{"km_from_home" => km_from_home},
         "last_transaction" => last_transaction
       }) do
    amount >= 10 and amount <= 500 and
      installments >= 1 and installments <= 3 and
      hour_between?(requested_at, 8, 20) and
      abs(avg_amount - amount * 2.0) <= 0.011 and
      tx_count_24h >= 1 and tx_count_24h <= 5 and
      merchant_id in known_merchants and
      mcc in ["5411", "5812", "5912", "5311"] and
      merchant_avg_amount >= 30 and merchant_avg_amount <= 500 and
      km_from_home >= 0 and km_from_home <= 50 and
      last_km_between?(last_transaction, 0, 20)
  end

  defp pure_fraud?(%{
         "transaction" => %{
           "amount" => amount,
           "installments" => installments,
           "requested_at" => requested_at
         },
         "customer" => %{
           "avg_amount" => avg_amount,
           "tx_count_24h" => tx_count_24h,
           "known_merchants" => known_merchants
         },
         "merchant" => %{
           "id" => merchant_id,
           "mcc" => mcc,
           "avg_amount" => merchant_avg_amount
         },
         "terminal" => %{"km_from_home" => km_from_home},
         "last_transaction" => last_transaction
       }) do
    amount >= 2000 and amount <= 10_000 and
      installments >= 6 and installments <= 12 and
      hour_between?(requested_at, 0, 6) and
      avg_amount >= 50 and avg_amount <= 300 and
      tx_count_24h >= 8 and tx_count_24h <= 20 and
      merchant_id not in known_merchants and
      mcc in ["7995", "7801", "7802"] and
      merchant_avg_amount >= 20 and merchant_avg_amount <= 100 and
      km_from_home >= 200 and km_from_home <= 1000 and
      last_km_between?(last_transaction, 200, 1000)
  end

  defp risky_borderline_fraud?(%{
         "transaction" => %{
           "amount" => amount,
           "installments" => installments
         },
         "customer" => %{
           "avg_amount" => avg_amount,
           "tx_count_24h" => tx_count_24h,
           "known_merchants" => known_merchants
         },
         "merchant" => %{"id" => merchant_id},
         "terminal" => %{
           "is_online" => true,
           "km_from_home" => km_from_home
         },
         "last_transaction" => %{"km_from_current" => km_from_current}
       }) do
    merchant_id not in known_merchants and
      amount > 1000 and
      amount / avg_amount > 8 and
      km_from_home > 100 and
      km_from_current > 250 and
      tx_count_24h <= 4 and
      installments <= 4
  end

  defp risky_borderline_fraud?(_tx), do: false

  defp hour_between?(<<_::binary-size(11), h1, h2, _::binary>>, min, max) do
    hour = (h1 - ?0) * 10 + (h2 - ?0)
    hour >= min and hour <= max
  end

  defp last_km_between?(:null, _min, _max), do: true

  defp last_km_between?(%{"km_from_current" => km_from_current}, min, max) do
    km_from_current >= min and km_from_current <= max
  end
end
