# frozen_string_literal: true

require "socket"
require "fcntl"
require "net/ftp"
require "orocos"

require "concurrent/atomic/atomic_reference"

module Syskit
    module ProcessManagers
        module Remote
            # Implementation of the syskit process server
            module Server
                extend Logger::Root(to_s, Logger::INFO)
            end
        end
    end
end

require "syskit/process_managers/remote/protocol"
require "syskit/roby_app/log_transfer_server/ftp_upload"
require "syskit/roby_app/log_transfer_server/log_upload_state"
require "syskit/process_managers/remote/server/process"
require "syskit/process_managers/remote/server/server"
