defmodule Solo.V1.SoloKernel.Service do
  @moduledoc false
  use GRPC.Service, name: "solo.v1.SoloKernel"

  rpc(:Deploy, Solo.V1.DeployRequest, Solo.V1.DeployResponse)
  rpc(:Status, Solo.V1.StatusRequest, Solo.V1.StatusResponse)
  rpc(:Kill, Solo.V1.KillRequest, Solo.V1.KillResponse)
  rpc(:List, Solo.V1.ListRequest, Solo.V1.ListResponse)
  rpc(:Watch, Solo.V1.WatchRequest, stream(Solo.V1.Event))
  rpc(:Shutdown, Solo.V1.ShutdownRequest, Solo.V1.ShutdownResponse)
  rpc(:RegisterService, Solo.V1.RegisterServiceRequest, Solo.V1.RegisterServiceResponse)
  rpc(:DiscoverService, Solo.V1.DiscoverServiceRequest, Solo.V1.DiscoverServiceResponse)
  rpc(:GetServices, Solo.V1.GetServicesRequest, Solo.V1.GetServicesResponse)
end

defmodule Solo.V1.SoloKernel.Stub do
  @moduledoc false
  use GRPC.Stub, service: Solo.V1.SoloKernel.Service
end
