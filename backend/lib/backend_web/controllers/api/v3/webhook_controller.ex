defmodule BackendWeb.Api.V3.WebhookController do
  use BackendWeb, :controller

  alias Backend.Workflow.WebhookHandler

  def replicate(conn, params) do
    Task.start(fn -> WebhookHandler.handle_event(params) end)
    json(conn, %{status: "ok"})
  end
end
