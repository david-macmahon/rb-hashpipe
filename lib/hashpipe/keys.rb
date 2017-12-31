module Hashpipe
  # Module containing methods for generating Hashpipe Redis key and channel
  # names.
  module RedisKeys
    def gw_inst_type(gwname, instance_id, type, domain=:hashpipe)
      "#{domain}://#{gwname}/#{instance_id ? "#{instance_id}/" : ''}#{type}"
    end
    module_function :gw_inst_type

    def status_key(gwname, instance_id, domain=:hashpipe)
      gw_inst_type(gwname, instance_id, :status, domain)
    end
    module_function :status_key

    def update_channel(gwname, instance_id, domain=:hashpipe)
      gw_inst_type(gwname, instance_id, :update, domain)
    end
    module_function :update_channel

    def set_channel(gwname, instance_id, domain=:hashpipe)
      gw_inst_type(gwname, instance_id, :set, domain)
    end
    module_function :set_channel

    def bcast_set_channel(domain=:hashpipe)
      gw_inst_type(nil, nil, :set, domain, domain)
      #'hashpipe:///set'
    end
    module_function :bcast_set_channel

    def gateway_channel(gwname, domain=:hashpipe)
      gw_inst_type(gwname, nil, :gateway, domain)
      #"hashpipe://#{gwname}/gateway"
    end
    module_function :gateway_channel

    def bcast_gateway_channel(domain=:hashpipe)
      gw_inst_type(nil, nil, :gateway, domain)
      #'hashpipe:///gateway'
    end
    module_function :bcast_gateway_channel
  end
end
