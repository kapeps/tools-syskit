# frozen_string_literal: true

# NOTE: this is NOT integrated in the Thor-based CLI to make it more independent
# (i.e. not depending on actually having Syskit installed)

require "pathname"
require "thor"
require "syskit/cli/log_runtime_archive"
require "syskit/roby_app/log_transfer_server/spawn_server"

module Syskit
    module CLI
        # Command-line definition for the cli-archive-main syskit subcommand
        class LogRuntimeArchiveMain < Thor
            def self.exit_on_failure?
                true
            end

            desc "watch", "watch a dataset root folder and call archiver"
            option :period,
                   type: :numeric, default: 600, desc: "polling period in seconds"
            option :max_size,
                   type: :numeric, default: 10_000, desc: "max log size in MB"
            option :free_space_low_limit,
                   type: :numeric, default: 5_000, desc: "start deleting files if \
                    available space is below this threshold (threshold in MB)"
            option :free_space_freed_limit,
                   type: :numeric, default: 25_000, desc: "stop deleting files if \
                    available space is above this threshold (threshold in MB)"
            default_task def watch(root_dir, target_dir)
                loop do
                    begin
                        archive(root_dir, target_dir)
                    rescue Errno::ENOSPC
                        next
                    end

                    puts "Archived pending logs, sleeping #{options[:period]}s"
                    sleep options[:period]
                end
            end

            desc "archive", "archive the datasets and manages disk space"
            option :max_size,
                   type: :numeric, default: 10_000, desc: "max log size in MB"
            option :free_space_low_limit,
                   type: :numeric, default: 5_000, desc: "start deleting files if \
                    available space is below this threshold (threshold in MB)"
            option :free_space_freed_limit,
                   type: :numeric, default: 25_000, desc: "stop deleting files if \
                    available space is above this threshold (threshold in MB)"
            def archive(root_dir, target_dir)
                root_dir = validate_directory_exists(root_dir)
                target_dir = validate_directory_exists(target_dir)
                archiver = make_archiver(root_dir, target_dir: target_dir)

                archiver.ensure_free_space(
                    options[:free_space_low_limit] * 1_000_000,
                    options[:free_space_freed_limit] * 1_000_000
                )
                archiver.process_root_folder
            end

            desc "watch_transfer", "watches a dataset root folder \
                                    and periodically performs transfer"
            option :period,
                   type: :numeric, default: 600, desc: "polling period in seconds"
            option :max_size,
                   type: :numeric, default: 10_000, desc: "max log size in MB"
            def watch_transfer( # rubocop:disable Metrics/ParameterLists
                base_log_dir, user, password, certfile_path, interface, port
            )
                loop do
                    begin
                        transfer(base_log_dir, user, password, certfile_path,
                                 interface, port)
                    rescue Errno::ENOSPC
                        next
                    end

                    puts "Transferred pending logs, sleeping #{options[:period]}s"
                    sleep options[:period]
                end
            end

            desc "transfer", "transfers the datasets"
            option :max_size,
                   type: :numeric, default: 10_000, desc: "max log size in MB"
            def transfer( # rubocop:disable Metrics/ParameterLists
                base_log_dir, user, password, certfile_path, interface, port
            )
                server_params = {
                    user: user, password: password, certfile_path: certfile_path,
                    interface: interface, port: port
                }
                base_log_dir = validate_directory_exists(base_log_dir)
                archiver = make_archiver(base_log_dir)

                archiver.process_root_folder_transfer(server_params)
            end

            desc "transfer_server", "creates the log transfer FTP server \
                                     that runs on the main computer"
            def transfer_server( # rubocop:disable Metrics/ParameterLists
                tgt_log_dir, user, password, certfile_path, interface, port
            )
                create_server(
                    tgt_log_dir, user, password, certfile_path, interface, port
                )
            end

            no_commands do # rubocop:disable Metrics/BlockLength
                def validate_directory_exists(dir)
                    dir = Pathname.new(dir)
                    unless dir.directory?
                        raise ArgumentError, "#{dir} does not exist, or is not a " \
                                             "directory"
                    end

                    dir
                end

                def make_archiver(root_dir, target_dir: nil)
                    logger = Logger.new($stdout)

                    Syskit::CLI::LogRuntimeArchive.new(
                        root_dir,
                        target_dir: target_dir, logger: logger,
                        max_archive_size: options[:max_size] * (1024**2)
                    )
                end

                def create_server( # rubocop:disable Metrics/ParameterLists
                    tgt_log_dir, user, password, certfile_path,
                    interface, port
                )
                    server = RobyApp::LogTransferServer::SpawnServer.new(
                        tgt_log_dir, user, password, certfile_path,
                        interface: interface, port: port
                    )
                    server.run
                    server
                end
            end
        end
    end
end
