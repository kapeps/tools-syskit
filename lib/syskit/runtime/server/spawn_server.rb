# frozen_string_literal: true

require "English"
require "syskit/runtime/server/driver"

module Syskit
    module Runtime
        module Server # :nodoc:
            # Whether we should configure client and server to use implicit FTPs by
            # default
            #
            # This workarounds some incompatibility between net-ftp and ftpd. They
            # don't manage connecting properly in implicit mode before 2.7.0, and
            # don't manage connecting properly in explicit mode afterwards
            def self.use_implicit_ftps?
                RUBY_VERSION >= "2.7.0"
            end

            # Class responsible for spawning an FTP server for transfering logs
            class SpawnServer
                attr_reader :port

                # tgt_dir must be an absolute path
                def initialize(
                    tgt_dir,
                    user,
                    password,
                    certfile_path,
                    interface: "127.0.0.1",
                    implicit_ftps: Server.use_implicit_ftps?,
                    port: 0,
                    session_timeout: default_session_timeout,
                    nat_ip: nil,
                    passive_ports: nil,
                    debug: false,
                    verbose: false
                )
                    @debug = debug
                    driver = Driver.new(user, password, tgt_dir)
                    server = Ftpd::FtpServer.new(driver)
                    server.interface = interface
                    server.port = port
                    server.tls = implicit_ftps ? :implicit : :explicit
                    server.passive_ports = passive_ports
                    server.certfile_path = certfile_path
                    server.auth_level = Ftpd.const_get("AUTH_PASSWORD")
                    server.session_timeout = session_timeout
                    server.log = make_log
                    server.nat_ip = nat_ip
                    @server = server
                    Thread.abort_on_exception = false
                    @server.start
                    sleep 0.1 until Thread.abort_on_exception
                    Thread.abort_on_exception = false
                    @port = @server.bound_port
                    display_connection_info if verbose
                end

                # The user should call this function in order to spawn the server
                def run
                    wait_until_stopped
                end

                def stop
                    dispose
                end

                def dispose
                    @server.stop
                end

                def join
                    @server.join
                end

                private

                def display_connection_info
                    puts "Interface: #{@server.interface}"
                    puts "Port: #{@server.bound_port}"
                    puts "TLS: #{@server.tls}"
                    puts "PID: #{$PROCESS_ID}"
                end

                def wait_until_stopped
                    puts "FTP server started.  Press ENTER or c-C to stop it"
                    $stdout.flush
                    begin
                        $stdin.readline
                    rescue Interrupt
                        puts "Interrupt"
                    end
                end

                def make_log
                    @debug && Logger.new($stdout)
                end

                def default_session_timeout
                    Ftpd::FtpServer::DEFAULT_SESSION_TIMEOUT
                end
            end
        end
    end
end
