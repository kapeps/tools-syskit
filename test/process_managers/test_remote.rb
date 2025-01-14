# frozen_string_literal: true

require "syskit/test/self"
require "syskit/process_managers/remote/server"

describe Syskit::ProcessManagers::Remote do
    attr_reader :server
    attr_reader :client
    attr_reader :root_loader

    before do
        @app = Roby::Application.new
        @process_server_log_base_path = make_tmppath
        @app.log_base_dir = @process_server_log_base_path.to_s
        @__server_current_log_level =
            Syskit::ProcessManagers::Remote::Server.logger.level
        Syskit::ProcessManagers::Remote::Server.logger.level = Logger::WARN
        @__orocos_current_log_level = Orocos.logger.level
        Orocos.logger.level = Logger::FATAL

        @root_loader = OroGen::Loaders::Aggregate.new
        OroGen::Loaders::RTT.setup_loader(root_loader)
    end

    after do
        if @server_thread&.alive?
            @server.quit
            @server_thread.join
        end
        @server&.close

        if @__server_current_log_level
            Syskit::ProcessManagers::Remote::Server.logger.level =
                @__server_current_log_level
        end

        if @gdb_pid
            Process.kill "KILL", @gdb_pid
            Process.wait @gdb_pid
        end

        Orocos.logger.level = @__orocos_current_log_level if @__orocos_current_log_level
    end

    describe "#initialize" do
        it "registers the loader exactly once on the provided root loader" do
            start_server
            client = Syskit::ProcessManagers::Remote::Manager.new(
                "localhost", server.port,
                root_loader: root_loader
            )
            assert_equal [client.loader], root_loader.loaders
        end
    end

    describe "#pid" do
        before do
            @client = start_and_connect_to_server
        end

        it "returns the process server's PID" do
            assert_equal Process.pid, client.server_pid
        end
    end

    describe "#loader" do
        attr_reader :loader

        before do
            @client = start_and_connect_to_server
            @loader = client.loader
        end

        it "knows about the available projects" do
            assert loader.available_projects.key?("orogen_syskit_tests")
        end

        it "knows about the available typekits" do
            assert loader.available_typekits.key?("orogen_syskit_tests")
        end

        it "knows about the available deployments" do
            assert loader.available_deployments.key?("syskit_tests_empty")
        end

        it "can load a remote project model" do
            assert loader.project_model_from_name("orogen_syskit_tests")
        end

        it "can load a remote typekit model" do
            assert loader.typekit_model_from_name("orogen_syskit_tests")
        end

        it "can load a remote deployment model" do
            assert loader.deployment_model_from_name("syskit_tests_empty")
        end
    end

    describe "#start" do
        before do
            @client = start_and_connect_to_server
        end

        it "returns a proper error message if the deployment does not exist remotely" do
            deployment_m = Syskit::Deployment.new_submodel(name: "does_not_exist")
            flexmock(client.root_loader)
                .should_receive(:deployment_model_from_name)
                .with("does_not_exist").and_return(deployment_m)
            flexmock(client.loader)
                .should_receive(:has_deployment?)
                .with("does_not_exist").and_return(true)
            e = assert_raises(Syskit::ProcessManagers::Remote::Manager::Failed) do
                client.start(
                    "some_name", "does_not_exist",
                    { "does_not_exist" => "some_name" },
                    oro_logfile: "/dev/null", output: "/dev/null"
                )
            end
            assert_equal(
                "failed to start some_name: cannot find deployment does_not_exist",
                e.message
            )
        end

        it "can start a process on the server" do
            process = client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => "syskit_tests_empty" },
                oro_logfile: "/dev/null", output: "/dev/null"
            )
            assert process.alive?
        end

        it "redirects the task's output to the process server's log dir" do
            process = client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => "syskit_tests_empty" },
                oro_logfile: "/dev/null"
            )
            assert process.alive?

            pid = process.pid
            path = @process_server_log_base_path.each_child.first / \
                   "syskit_tests_empty-#{pid}.txt"
            assert path.exist?
        end

        it "executes the task under valgrind if configured to do so" do
            process = client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => "syskit_tests_empty" },
                oro_logfile: "/dev/null",
                execution_mode: { type: :valgrind }
            )
            assert process.alive?
            wait_running_process(process, timeout: 60)

            pid = process.pid
            path = @process_server_log_base_path.each_child.first / \
                   "syskit_tests_empty-#{pid}.valgrind.txt"
            assert path.exist?
        end

        it "executes the task under gdb if configured to do so" do
            skip "gdbserver support is known to be broken"

            port = allocate_gdb_port
            process = client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => "syskit_tests_empty" },
                oro_logfile: "/dev/null",
                execution_mode: { type: :gdbserver, port: port }
            )

            binfile = Roby.app.default_pkgconfig_loader
                          .find_deployment_binfile("syskit_tests_empty")
            wait_for_gdb_ready(port)
            $stderr.puts "READY"
            puts <<~SCRIPT
                file #{binfile}
                target remote 127.0.0.1:#{port}
                continue
                quit
            SCRIPT
            $stdin.readline
            execute_gdb_script(<<~SCRIPT)
                file #{binfile}
                target remote 127.0.0.1:#{port}
                continue
                quit
            SCRIPT

            wait_running_process(process)
        end

        it "raises if the deployment does not exist on the remote server" do
            assert_raises(OroGen::DeploymentModelNotFound) do
                client.start "bla", "bla", Hash["sink" => "test"]
            end
        end

        it "raises if the deployment does exist locally but not on the remote server" do
            project    = OroGen::Spec::Project.new(root_loader)
            deployment = project.deployment "test"
            root_loader.register_deployment_model(deployment)
            assert_raises(OroGen::DeploymentModelNotFound) do
                client.start "test", "test"
            end
        end

        it "uses the deployment model loaded on the root loader" do
            project    = OroGen::Spec::Project.new(root_loader)
            deployment = project.deployment "syskit_tests_empty"
            root_loader.register_deployment_model(deployment)
            process = client.start(
                "syskit_tests_empty", "syskit_tests_empty", {},
                oro_logfile: nil, output: "/dev/null"
            )

            assert_same deployment, process.model
        end

        it "registers the task on the name server if directed to do so" do
            project    = OroGen::Spec::Project.new(root_loader)
            deployment = project.deployment "syskit_tests_empty"
            root_loader.register_deployment_model(deployment)
            task_name = "syskit-remote-process-tests-#{Process.pid}"
            process = client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => task_name },
                oro_logfile: nil, output: "/tmp/out",
                register_on_name_server: true
            )
            result = wait_running_process(process)
            task = Orocos.allow_blocking_calls { Orocos.name_service.get task_name }
            assert_equal result[:iors][task_name],
                         task.ior
        end

        it "does not register the task on the name server if registration is disabled" do
            project    = OroGen::Spec::Project.new(root_loader)
            deployment = project.deployment "syskit_tests_empty"
            root_loader.register_deployment_model(deployment)
            task_name = "syskit-remote-process-tests-#{Process.pid}"
            process = client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => task_name },
                oro_logfile: nil, output: "/tmp/out",
                register_on_name_server: false
            )
            result = wait_running_process(process)
            task = Orocos.allow_blocking_calls { Orocos.name_service.get task_name }
            refute_equal result[:iors][task_name],
                         task.ior
        rescue Orocos::NotFound
            # Expected behavior
            assert(true)
        end
    end

    describe "waits for the process to be running" do
        before do
            @client = start_and_connect_to_server
        end

        it "eventually returns a hash with information about a process and its tasks" do
            process = client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => "syskit_tests_empty" },
                oro_logfile: nil, output: "/dev/null"
            )
            result = wait_running_process(process)

            assert_match(
                /^IOR/,
                result[:iors]["syskit_tests_empty"]
            )
        end

        it "returns a hash without any info when the process didnt get its tasks ior" do
            client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => "syskit_tests_empty" },
                oro_logfile: nil, output: "/dev/null"
            )
            result = client.wait_running("syskit_tests_empty")
            assert_equal({ "syskit_tests_empty" => nil }, result)
        end

        it "reports when a runtime error occured" do
            runtime_error_message = "some runtime error occured"
            flexmock(Syskit::ProcessManagers::Remote::Server::Process)
                .new_instances
                .should_receive(:wait_running)
                .and_raise(RuntimeError, runtime_error_message)

            client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => "syskit_tests_empty" },
                oro_logfile: nil, output: "/dev/null"
            )
            result = client.wait_running("syskit_tests_empty")
            expected = {
                "syskit_tests_empty" => { error: runtime_error_message }
            }
            assert_equal(expected, result)
        end
    end

    describe "stopping a remote process" do
        attr_reader :process

        before do
            @client = start_and_connect_to_server
            @process = client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => "syskit_tests_empty" },
                oro_logfile: nil, output: "/dev/null"
            )
        end

        it "kills an already started process" do
            process.kill
            process.join
            assert_raises Orocos::NotFound do
                Orocos.allow_blocking_calls do
                    Orocos.get "syskit_tests_empty"
                end
            end
        end

        it "gets notified if a remote process dies" do
            Process.kill "KILL", process.pid
            dead_processes = client.wait_termination
            assert dead_processes[process]
            assert !process.alive?
        end
    end

    describe "stopping all remote processes" do
        before do
            @client = start_and_connect_to_server
            @processes = 10.times.map do |i|
                client.start(
                    "syskit_tests_empty_#{i}", "syskit_tests_empty",
                    { "syskit_tests_empty" => "syskit_tests_empty_#{i}",
                      "syskit_tests_empty_Logger" => "syskit_tests_empty_#{i}_Logger" },
                    oro_logfile: nil, output: "/dev/null"
                )
            end
        end

        it "kills all remote processes and waits for all of them to stop" do
            killed = client.kill_all
            killed_names = killed.map { |process_name, _| process_name }
            assert_equal killed_names.to_set, @processes.map(&:name).to_set

            @processes.all? do |p|
                Process.wait2(p.pid, Process::WNOHANG)
                flunk("#{p.pid} has either not been killed or not been reaped")
            rescue Errno::ECHILD
                assert(true)
            end
        end

        it "does not send for a notification that the process died" do
            client.kill_all
            sleep 2
            assert client.wait_termination(0).empty?
        end
    end

    describe "#log_upload_file" do
        before do
            @client = start_and_connect_to_server
            @port, @certificate = spawn_log_transfer_server
            @logfile = Pathname(@app.log_dir) / "logfile.log"
            create_logfile(547)
        end

        after do
            @log_transfer_server&.stop
            @log_transfer_server&.join
        end

        it "uploads a file" do
            path = File.join(@temp_serverdir, "logfile.log")
            refute File.exist?(path)
            client.log_upload_file(
                "localhost", @port, @certificate,
                @user, @password, @logfile
            )
            assert_upload_succeeds
            assert_equal @logfile_contents, File.read(path)
            refute File.exist?(@logfile)
        end

        it "rate-limits the file transfer" do
            create_logfile(1024 * 1024)
            tic = Time.now
            client.log_upload_file(
                "localhost", @port, @certificate,
                @user, @password, @logfile,
                max_upload_rate: 500 * 1024
            )
            assert_upload_succeeds(timeout: 5)
            toc = Time.now

            assert_includes(
                (1.8..2.2), toc - tic,
                "transfer took #{toc - tic} instead of the expected 2s"
            )
            path = File.join(@temp_serverdir, "logfile.log")
            assert_equal @logfile_contents, File.read(path)
        end

        it "rejects a wrong user" do
            client.log_upload_file(
                "localhost", @port, @certificate,
                "somethingsomething", @password, @logfile
            )

            state = wait_for_upload_completion
            result = state.each_result.first
            assert_equal @logfile, result.file
            refute result.success?
            assert_match(/Login incorrect/, result.message)
        end

        it "rejects a wrong password" do
            client.log_upload_file(
                "localhost", @port, @certificate,
                @user, "somethingsomething", @logfile
            )

            state = wait_for_upload_completion
            result = state.each_result.first
            assert_equal @logfile, result.file
            refute result.success?
            assert_match(/Login incorrect/, result.message)
        end

        it "refuses to overwrite an existing file" do
            FileUtils.touch File.join(@temp_serverdir, "logfile.log")
            client.log_upload_file(
                "localhost", @port, @certificate,
                @user, @password, @logfile
            )

            state = wait_for_upload_completion
            result = state.each_result.first
            assert_equal @logfile, result.file
            refute result.success?
            assert_match(/File already exists/, result.message)
            # Does not delete the file
            assert File.file?(@logfile)
        end

        it "fails on an invalid certificate" do
            certfile_path = File.join(__dir__, "invalid-cert.crt")
            client.log_upload_file(
                "localhost", @port, File.read(certfile_path),
                @user, @password, @logfile
            )

            state = wait_for_upload_completion
            result = state.each_result.first
            assert_equal @logfile, result.file
            refute result.success?
            assert_match(/certificate verify failed/, result.message)
        end

        def create_logfile(size)
            @logfile.write(SecureRandom.random_bytes(size))
            @logfile_contents = @logfile.read
        end

        def spawn_log_transfer_server
            @temp_serverdir = make_tmpdir
            @user = "test.user"
            @password = "password123"
            @log_transfer_server = TestLogTransferServer.new(
                @temp_serverdir, @user, @password
            )
            [@log_transfer_server.port, File.read(@log_transfer_server.certfile_path)]
        end

        def wait_for_upload_completion(poll_period: 0.01, timeout: 1)
            deadline = Time.now + timeout
            loop do
                if Time.now > deadline
                    flunk("timed out while waiting for upload completion")
                end

                state = client.log_upload_state
                return state if state.pending_count == 0

                sleep poll_period
            end
        end

        def assert_upload_succeeds(timeout: 1)
            wait_for_upload_completion(timeout: timeout).each_result do |r|
                flunk("upload failed: #{r.message}") unless r.success?
            end
        end
    end

    class TestLogTransferServer < Syskit::Runtime::Server::SpawnServer
        attr_reader :certfile_path

        def initialize(target_dir, user, password)
            @certfile_path = File.join(__dir__, "cert.crt")
            private_cert = File.join(__dir__, "cert-private.crt")
            super(target_dir, user, password, private_cert)
        end
    end

    def start_server
        raise "server already started" if @server

        @server = Syskit::ProcessManagers::Remote::Server::Server.new(
            @app, port: 0, name_service_ip: "127.0.0.1"
        )
        server.open
        @server_thread = Thread.new { server.listen }
    end

    def connect_to_server
        client = Syskit::ProcessManagers::Remote::Manager.new(
            "localhost", server.port, root_loader: root_loader
        )

        client.create_log_dir(Roby.app.time_tag)
        client
    end

    def start_and_connect_to_server
        start_server
        connect_to_server
    end

    def wait_running_process(process, timeout: 20)
        deadline = Time.now + timeout
        while Time.now < deadline
            if (r = query_process_running(process))
                return r
            end

            sleep 0.01
        end
        flunk("did not manage to get a running #{process} in #{timeout} seconds")
    end

    # Query {#client} to check whether the given process is running
    #
    # @return [nil,Hash] nil if the process is not ready, and the process-specific hash
    #   returned by the process server otherwise
    # @raise if the process finished or died, or if the remote process server reports
    #   an error
    def query_process_running(process)
        result = client.wait_running(process.name)
        return unless (r = result[process.name])
        return r if r.key?(:iors)

        result = client.wait_termination
        raise "process #{process.name} unexpectedly terminated" if result[process]

        raise r[:error]
    end

    def allocate_gdb_port
        server = TCPServer.new(0)
        server.local_address.ip_port
    ensure
        server&.close
    end

    def wait_for_gdb_ready(port, timeout: 5)
        deadline = Time.now + timeout

        until deadline
            begin
                TCPSocket.new(port).close
                break
            rescue StandardError
                sleep 0.1
            end
        end
    end

    def execute_gdb_script(script)
        @gdb_script = Tempfile.open("w")
        @gdb_script.write script
        @gdb_script.flush
        puts script
        sleep 1

        @gdb_pid = spawn("gdb", "-x", @gdb_script.path)
    end
end
