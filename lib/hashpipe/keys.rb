module Hashpipe
  # Module containing methods for generating Hashpipe Redis key and channel
  # names.
  module RedisKeys
    def gw_inst_type(gwname, instance_id, type)
      "hashpipe://#{gwname}/#{instance_id ? "#{instance_id}/" : ''}#{type}"
    end
    module_function :gw_inst_type

    def status_key(gwname, instance_id)
      gw_inst_type(gwname, instance_id, :status)
    end
    module_function :status_key

    def update_channel(gwname, instance_id)
      gw_inst_type(gwname, instance_id, :update)
    end
    module_function :update_channel

    def set_channel(gwname, instance_id)
      gw_inst_type(gwname, instance_id, :set)
    end
    module_function :set_channel

    def bcast_set_channel
      gw_inst_type(nil, nil, :set)
      #'hashpipe:///set'
    end
    module_function :bcast_set_channel

    def gateway_channel(gwname)
      gw_inst_type(gwname, nil, :gateway)
      #"hashpipe://#{gwname}/gateway"
    end
    module_function :gateway_channel

    def bcast_gateway_channel
      gw_inst_type(nil, nil, :gateway)
      #'hashpipe:///gateway'
    end
    module_function :bcast_gateway_channel
  end
end
