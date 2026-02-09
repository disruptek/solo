defmodule Solo.V1.DeployRequest.DeployFormat do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:DEPLOY_FORMAT_UNSPECIFIED, 0)
  field(:ELIXIR_SOURCE, 1)
end

defmodule Solo.V1.DeployRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_id, 1, type: :string)
  field(:code, 2, type: :string)
  field(:format, 3, type: Solo.V1.DeployRequest.DeployFormat, enum: true)
end

defmodule Solo.V1.DeployResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_id, 1, type: :string)
  field(:status, 2, type: :string)
  field(:error, 3, type: :string)
end

defmodule Solo.V1.StatusRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_id, 1, type: :string)
end

defmodule Solo.V1.StatusResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_id, 1, type: :string)
  field(:alive, 2, type: :bool)
  field(:memory_bytes, 3, type: :int64)
  field(:message_queue_len, 4, type: :int64)
  field(:reductions, 5, type: :int64)
end

defmodule Solo.V1.KillRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_id, 1, type: :string)
  field(:timeout_ms, 2, type: :int32)
  field(:force, 3, type: :bool)
end

defmodule Solo.V1.KillResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_id, 1, type: :string)
  field(:status, 2, type: :string)
  field(:error, 3, type: :string)
end

defmodule Solo.V1.ListRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3
end

defmodule Solo.V1.ServiceInfo do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_id, 1, type: :string)
  field(:alive, 2, type: :bool)
end

defmodule Solo.V1.ListResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:services, 1, repeated: true, type: Solo.V1.ServiceInfo)
end

defmodule Solo.V1.WatchRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_id, 1, type: :string)
  field(:include_logs, 2, type: :bool)
end

defmodule Solo.V1.Event do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:id, 1, type: :uint64)
  field(:timestamp, 2, type: :int64)
  field(:event_type, 3, type: :string)
  field(:subject, 4, type: :string)
  field(:payload, 5, type: :bytes)
  field(:causation_id, 6, type: :uint64)
end

defmodule Solo.V1.ShutdownRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:grace_period_ms, 1, type: :int32)
end

defmodule Solo.V1.ShutdownResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:status, 1, type: :string)
  field(:message, 2, type: :string)
end

# Service Discovery Messages

defmodule Solo.V1.ServiceMetadata do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Solo.V1.RegisterServiceRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_id, 1, type: :string)
  field(:service_name, 2, type: :string)
  field(:version, 3, type: :string)
  field(:metadata, 4, repeated: true, type: Solo.V1.ServiceMetadata, map: true)
  field(:ttl_seconds, 5, type: :int32)
end

defmodule Solo.V1.RegisterServiceResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:registered, 1, type: :bool)
  field(:service_handle, 2, type: :string)
  field(:error, 3, type: :string)
end

defmodule Solo.V1.DiscoverServiceRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_name, 1, type: :string)
  field(:filters, 2, repeated: true, type: Solo.V1.ServiceMetadata, map: true)
end

defmodule Solo.V1.DiscoveredService do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_id, 1, type: :string)
  field(:service_handle, 2, type: :string)
  field(:service_name, 3, type: :string)
  field(:version, 4, type: :string)
  field(:alive, 5, type: :bool)
  field(:metadata, 6, repeated: true, type: Solo.V1.ServiceMetadata, map: true)
end

defmodule Solo.V1.DiscoverServiceResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:services, 1, repeated: true, type: Solo.V1.DiscoveredService)
end

defmodule Solo.V1.GetServicesRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:service_name, 1, type: :string)
end

defmodule Solo.V1.GetServicesResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:services, 1, repeated: true, type: Solo.V1.DiscoveredService)
  field(:total_count, 2, type: :int64)
end
