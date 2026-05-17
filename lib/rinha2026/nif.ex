defmodule Rinha2026.NIF do
  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:rinha_2026), "rinha_nif")
    :erlang.load_nif(path, 0)
  end

  def knn(_vector) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def load_dataset(_dataset_path, _offsets_path, _ivf_dataset_path, _ivf_offsets_path, _ivf_centroids_path) do
    :erlang.nif_error(:nif_not_loaded)
  end
end
