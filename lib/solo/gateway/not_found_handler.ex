defmodule Solo.Gateway.NotFoundHandler do
  @moduledoc """
  Cowboy HTTP handler for 404 responses.
  """

  def init(req, state) do
    req =
      :cowboy_req.reply(
        404,
        %{"content-type" => "application/json"},
        Jason.encode!(%{error: "not_found", message: "Endpoint not found"}),
        req
      )

    {:ok, req, state}
  end
end
