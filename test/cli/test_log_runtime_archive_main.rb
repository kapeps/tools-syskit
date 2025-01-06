# frozen_string_literal: true

require "syskit/test/self"
require "syskit/cli/log_runtime_archive_main"
require "syskit/roby_app/tmp_root_ca"

module Syskit
    module CLI
        # Tests CLI command "archive" from syskit/cli/log_runtime_archive_main.rb
        describe LogRuntimeArchiveMain do
            describe "#watch" do
                before do
                    @root = make_tmppath
                    @archive_dir = make_tmppath

                    @mocked_files_sizes = []
                    5.times { |i| (@archive_dir / i.to_s).write(i.to_s) }
                end

                it "calls archive with the specified period" do
                    mock_files_size([])
                    mock_available_space(200) # 70 MB

                    quit = Class.new(RuntimeError)
                    called = 0
                    flexmock(LogRuntimeArchive)
                        .new_instances
                        .should_receive(:process_root_folder)
                        .pass_thru do
                            called += 1
                            raise quit if called == 3
                        end

                    tic = Time.now
                    assert_raises(quit) do
                        LogRuntimeArchiveMain.start(
                            ["watch", @root, @archive_dir, "--period", 0.5]
                        )
                    end

                    assert called == 3
                    assert_operator(Time.now - tic, :>, 0.9)
                end

                it "retries on ENOSPC" do
                    mock_files_size([])
                    mock_available_space(200) # 70 MB

                    quit = Class.new(RuntimeError)
                    called = 0
                    flexmock(LogRuntimeArchive)
                        .new_instances
                        .should_receive(:process_root_folder)
                        .pass_thru do
                            called += 1
                            raise quit if called == 3

                            raise Errno::ENOSPC
                        end

                    tic = Time.now
                    assert_raises(quit) do
                        LogRuntimeArchiveMain.start(
                            ["watch", @root, @archive_dir, "--period", 0.5]
                        )
                    end
                    assert_operator(Time.now - tic, :<, 1)
                end
            end

            describe "#archive" do
                before do
                    @root = make_tmppath
                    @archive_dir = make_tmppath
                    @mocked_files_sizes = []

                    5.times { |i| (@archive_dir / i.to_s).write(i.to_s) }
                end

                it "raises ArgumentError if the source directory does not exist" do
                    e = assert_raises ArgumentError do
                        call_archive("/does/not/exist", @archive_dir, 1, 10)
                    end
                    assert_equal "/does/not/exist does not exist, or is not a directory",
                                 e.message
                end

                it "raises ArgumentError if the target directory does not exist" do
                    e = assert_raises ArgumentError do
                        call_archive(@root, "/does/not/exist", 1, 10)
                    end
                    assert_equal "/does/not/exist does not exist, or is not a directory",
                                 e.message
                end

                it "does nothing if there is enough free space" do
                    mock_available_space(200)
                    call_archive(@root, @archive_dir, 100, 300) # 100 MB, 300 MB

                    assert_deleted_files([])
                end

                it "removes enough files to reach the freed limit" do
                    size_files = [75, 40, 90, 60, 70]
                    mock_files_size(size_files)
                    mock_available_space(70) # 70 MB

                    call_archive(@root, @archive_dir, 100, 300) # 100 MB, 300 MB
                    assert_deleted_files([0, 1, 2, 3])
                end

                it "stops removing files when there is no file in folder even if freed
                    limit is not achieved" do
                    size_files = Array.new(5, 10)
                    mock_files_size(size_files)
                    mock_available_space(80) # 80 MB

                    call_archive(@root, @archive_dir, 100, 300) # 100 MB, 300 MB
                    assert_deleted_files([0, 1, 2, 3, 4])
                end

                # Call 'archive' function instead of 'watch' to call archiver once
                def call_archive(root_path, archive_path, low_limit, freed_limit)
                    LogRuntimeArchiveMain.start(
                        ["archive", root_path, archive_path,
                         "--free-space-low-limit", low_limit,
                         "--free-space-freed-limit", freed_limit]
                    )
                end
            end

            describe "#watch_transfer" do
                before do
                    @base_log_dir = make_tmppath
                    @tgt_log_dir = make_tmppath
                    interface = "127.0.0.1"
                    ca = RobyApp::TmpRootCA.new(interface)

                    @server_params = {
                        host: interface, port: 0,
                        certficate: ca.private_certificate_path,
                        user: "nilvo", password: "nilvo123",
                        max_upload_rate: 10,
                        implicit_ftps: true
                    }
                    @threads = []
                    server = nil
                    flexmock(Runtime::Server::SpawnServer)
                        .should_receive(:new)
                        .with_any_args
                        .pass_thru do |arg|
                            server = arg
                        end
                    call_create_server
                    @server = server
                end

                after do
                    @server.stop
                    @server.join
                    @threads.each(&:kill)
                end

                it "calls transfer with the specified period" do
                    quit = Class.new(RuntimeError)
                    called = 0
                    flexmock(LogRuntimeArchive)
                        .new_instances
                        .should_receive(:process_root_folder_transfer)
                        .with(@server_params)
                        .pass_thru do
                            called += 1
                            raise quit if called == 3
                        end

                    tic = Time.now
                    assert_raises(quit) do
                        args = [
                            "watch_transfer",
                            @base_log_dir,
                            *@server_params.values,
                            "--period", 0.5
                        ]
                        LogRuntimeArchiveMain.start(args)
                    end

                    assert called == 3
                    assert_operator(Time.now - tic, :>, 0.9)
                end

                def call_create_server
                    cli = LogRuntimeArchiveMain.new
                    modified_params = @server_params.dup
                    modified_params.delete(:max_upload_rate)
                    cli.create_server(@tgt_log_dir, *modified_params.values)
                end
            end

            describe "#transfer" do
                before do
                    @base_log_dir = make_tmppath
                end

                # Call 'transfer' function instead of 'watch' to call transfer once
                def call_transfer(src_dir, params)
                    args = [
                        "transfer",
                        src_dir,
                        *params.values
                    ]
                    LogRuntimeArchiveMain.start(args)
                end
            end

            # Mock files sizes in bytes
            # @param [Array] size of files in MB
            def mock_files_size(sizes)
                @mocked_files_sizes = sizes
                @mocked_files_sizes.each_with_index do |size, i|
                    (@archive_dir / i.to_s).write(" " * size * 1e6)
                end
            end

            # Mock total disk available space in bytes
            # @param [Float] total_available_disk_space total available space in MB
            def mock_available_space(total_available_disk_space)
                flexmock(Sys::Filesystem)
                    .should_receive(:stat).with(@archive_dir)
                    .and_return do
                        flexmock(
                            bytes_available: total_available_disk_space * 1e6
                        )
                    end
            end

            def assert_deleted_files(deleted_files)
                if deleted_files.empty?
                    files = @archive_dir.each_child.select(&:file?)
                    assert_equal 5, files.size
                else
                    (0..4).each do |i|
                        if deleted_files.include?(i)
                            refute (@archive_dir / i.to_s).exist?,
                                   "#{i} was expected to be deleted, but has not been"
                        else
                            assert (@archive_dir / i.to_s).exist?,
                                   "#{i} was expected to be present, but got deleted"
                        end
                    end
                end
            end
        end
    end
end
