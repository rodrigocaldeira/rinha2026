defmodule Rinha2026.Vectorizer do
  @max_amount 10_000
  @max_installments 12
  @amount_vs_avg_ratio 10
  @max_minutes 1440
  @max_km 1000
  @max_tx_count_24h 20
  @max_merchant_avg_amount 10_000
  @mcc_risk %{
    "5411" => 0.15,
    "5812" => 0.30,
    "5912" => 0.20,
    "5944" => 0.45,
    "7801" => 0.80,
    "7802" => 0.75,
    "7995" => 0.85,
    "4511" => 0.35,
    "5311" => 0.25,
    "5999" => 0.50
  }

  def vectorize(tx) do
    requested_at = tx["transaction"]["requested_at"]
    last_transaction_at = get_last_transaction_at(tx)

    <<
      quantize(clamp(tx["transaction"]["amount"] / @max_amount))::little-unsigned-integer-16,
      quantize(clamp(tx["transaction"]["installments"] / @max_installments))::little-unsigned-integer-16,
      quantize(
        clamp(tx["transaction"]["amount"] / tx["customer"]["avg_amount"] / @amount_vs_avg_ratio)
      )::little-unsigned-integer-16,
      quantize(hour_of_day(tx["transaction"]["requested_at"]))::little-unsigned-integer-16,
      quantize(day_of_week(tx["transaction"]["requested_at"]))::little-unsigned-integer-16,
      quantize(minutes_since_last_tx(requested_at, last_transaction_at))::little-unsigned-integer-16,
      quantize(km_from_last_tx(tx))::little-unsigned-integer-16,
      quantize(clamp(tx["terminal"]["km_from_home"] / @max_km))::little-unsigned-integer-16,
      quantize(clamp(tx["customer"]["tx_count_24h"] / @max_tx_count_24h))::little-unsigned-integer-16,
      quantize(is_online(tx))::little-unsigned-integer-16,
      quantize(card_present(tx))::little-unsigned-integer-16,
      quantize(unknown_merchant(tx))::little-unsigned-integer-16,
      quantize(mcc_risk(tx))::little-unsigned-integer-16,
      quantize(clamp(tx["merchant"]["avg_amount"] / @max_merchant_avg_amount))::little-unsigned-integer-16
    >>
  end

  defp quantize(value) when value in [-1, -1.0], do: 65535
  defp quantize(value), do: round(value * 65534)

  defp get_last_transaction_at(%{"last_transaction" => :null}), do: nil

  defp get_last_transaction_at(%{"last_transaction" => %{"timestamp" => timestamp}}) do
    timestamp
  end

  defp clamp(val), do: clamp(val, 0.0, 1.0)
  defp clamp(val, _min, max) when val > max, do: max
  defp clamp(val, min, _max) when val < min, do: min
  defp clamp(val, _min, _max), do: val

  defp hour_of_day(<<
         _::binary-size(11),
         h1,
         h2,
         _::binary
       >>) do
    ((h1 - ?0) * 10 + (h2 - ?0)) / 23
  end

  defp extract_date(<<
         y1,
         y2,
         y3,
         y4,
         ?-,
         m1,
         m2,
         ?-,
         d1,
         d2,
         _::binary
       >>) do
    year =
      (y1 - ?0) * 1000 +
        (y2 - ?0) * 100 +
        (y3 - ?0) * 10 +
        (y4 - ?0)

    month =
      (m1 - ?0) * 10 +
        (m2 - ?0)

    day =
      (d1 - ?0) * 10 +
        (d2 - ?0)

    {year, month, day}
  end

  @t {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4}

  defp weekday(year, month, day) do
    year =
      if month < 3 do
        year - 1
      else
        year
      end

    t = elem(@t, month - 1)

    rem(
      year +
        div(year, 4) -
        div(year, 100) +
        div(year, 400) +
        t +
        day,
      7
    )
    |> case do
      0 -> 6
      n -> n - 1
    end
  end

  defp timestamp_to_minutes(<<
         y1,
         y2,
         y3,
         y4,
         ?-,
         mo1,
         mo2,
         ?-,
         d1,
         d2,
         ?T,
         h1,
         h2,
         ?:,
         mi1,
         mi2,
         _::binary
       >>) do
    year =
      (y1 - ?0) * 1000 +
        (y2 - ?0) * 100 +
        (y3 - ?0) * 10 +
        (y4 - ?0)

    month =
      (mo1 - ?0) * 10 +
        (mo2 - ?0)

    day =
      (d1 - ?0) * 10 +
        (d2 - ?0)

    hour =
      (h1 - ?0) * 10 +
        (h2 - ?0)

    minute =
      (mi1 - ?0) * 10 +
        (mi2 - ?0)

    days = days_since_epoch(year, month, day)

    days * 1440 + hour * 60 + minute
  end

  defp days_since_epoch(year, month, day) do
    y =
      if month <= 2 do
        year - 1
      else
        year
      end

    era = div(y, 400)

    yoe = y - era * 400

    doy =
      div(153 * (month + if(month > 2, do: -3, else: 9)) + 2, 5) + day - 1

    doe =
      yoe * 365 +
        div(yoe, 4) -
        div(yoe, 100) +
        doy

    era * 146_097 + doe
  end

  defp day_of_week(date) do
    {y, m, d} = extract_date(date)

    weekday(y, m, d) / 6
  end

  defp minutes_since_last_tx(_requested_at, nil), do: -1.0

  defp minutes_since_last_tx(requested_at, last_transaction_at) do
    clamp(
      (timestamp_to_minutes(requested_at) -
         timestamp_to_minutes(last_transaction_at)) /
        @max_minutes
    )
  end

  defp km_from_last_tx(%{"last_transaction" => :null}), do: -1

  defp km_from_last_tx(%{"last_transaction" => %{"km_from_current" => km}}) do
    clamp(km / @max_km)
  end

  defp is_online(%{"terminal" => %{"is_online" => true}}), do: 1
  defp is_online(%{"terminal" => %{"is_online" => false}}), do: 0

  defp card_present(%{"terminal" => %{"card_present" => true}}), do: 1
  defp card_present(%{"terminal" => %{"card_present" => false}}), do: 0

  defp unknown_merchant(%{
         "merchant" => %{"id" => id},
         "customer" => %{"known_merchants" => known_merchants}
       }) do
    if Enum.member?(known_merchants, id) do
      0
    else
      1
    end
  end

  defp mcc_risk(%{"merchant" => %{"mcc" => mcc}}), do: Map.get(@mcc_risk, mcc, 0.5)
end
