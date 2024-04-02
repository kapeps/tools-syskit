# frozen_string_literal: true

require "roby/interface/base"

module Syskit
    module Telemetry
        # Implementation of `syskit telemetry`
        class CLI < Thor
            desc "ui",
                 "open a UI to interface with a running Syskit system"
            option :host,
                   type: :string, doc: "host[:port] to connect to",
                   default: "localhost:#{Roby::Interface::DEFAULT_PORT}"
            def ui
                roby_setup
                host, port = parse_host_port(
                    options[:host], default_port: Roby::Interface::DEFAULT_PORT
                )

                require "syskit/telemetry/ui/runtime_state"
                $qApp.disable_threading # rubocop:disable Style/GlobalVars

                require "syskit/scripts/common"
                Syskit::Scripts.run do
                end
            end

            no_commands do
                def roby_setup
                    Roby.app.using "syskit"
                    Syskit.conf.only_load_models = true
                    # We don't need the process server, win some startup time
                    Syskit.conf.disables_local_process_server = true
                    Roby.app.ignore_all_load_errors = true
                    Roby.app.development_mode = false

                    Roby.app.auto_load_all = false
                    Roby.app.auto_load_models = false
                end

                def parse_host_port(host_port, default_port:)
                    host_port += ":#{default_port}" unless /:\d+$/.match?(host_port)
                    match = /(.*):(\d+)$/.match(host_port)
                    [match[1], Integer(match[2])]
                end
            end
        end
    end
end
