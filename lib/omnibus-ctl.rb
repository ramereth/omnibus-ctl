#  Copyright (c) 2012-2015 Chef Software, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "omnibus-ctl/version"
require "chef-utils/dist" unless defined?(ChefUtils)
require "json" unless defined?(JSON)
require "fileutils" unless defined?(FileUtils)

# For license checks
require "io/console"
require "io/wait"

module Omnibus
  class Ctl

    File.umask(022)

    SV_COMMAND_NAMES = %w{status up down once pause cont hup alarm int quit
                      term kill start stop restart shutdown force-stop
                      force-reload force-restart force-shutdown check usr1 usr2}.freeze

    attr_accessor :name, :display_name, :log_exclude, :base_path, :sv_path,
    :service_path, :etc_path, :data_path, :log_path, :command_map, :category_command_map,
    :fh_output, :kill_users, :verbose, :log_path_exclude

    attr_reader :backup_dir, :exe_name

    def initialize(name, merge_service_commands = true, disp_name = nil)
      @name = name
      @service_commands = merge_service_commands
      @display_name = disp_name || name
      @base_path = "/opt/#{name}"
      @sv_path = File.join(@base_path, "sv")
      @service_path = File.join(@base_path, "service")
      @log_path = "/var/log/#{name}"
      @data_path = "/var/opt/#{name}"
      @etc_path = "/etc/#{name}"
      @log_exclude = "(config|lock|@|bz2|gz|gzip|tbz2|tgz|txz|xz|zip)"
      @log_path_exclude = ["*/sasl/*"]
      @fh_output = STDOUT
      @kill_users = []
      @verbose = false
      @quiet = false
      @exe_name = File.basename($0)
      @force_exit = false
      @global_pre_hooks = {}

      # TODO(ssd) 2017-03-28: Set SVDIR explicitly. Once we fix a bug
      # in our debian support, where we rely on system-installed
      # runit, we can likely change this back to ENV.delete("SVDIR")
      ENV["SVDIR"] = service_path

      # backwards compat command map that does not have categories
      @command_map = {}

      # categoired commands that we want by default
      @category_command_map = {
        "general" => {
          "show-config" => {
            desc: "Show the configuration that would be generated by reconfigure.",
            arity: 1,
          },
          "reconfigure" => {
            desc: "Reconfigure the application.",
            arity: 2,
          },
          "cleanse" => {
            desc: "Delete *all* #{display_name} data, and start from scratch.",
            arity: 2,
          },
          "uninstall" => {
            arity: 1,
            desc: "Kill all processes and uninstall the process supervisor (data will be preserved).",
          },
          "help" => {
            arity: 1,
            desc: "Print this help message.",
          },
        },
      }
      service_command_map = {
        "service-management" => {
          "service-list" => {
            arity: 1,
            desc: "List all the services (enabled services appear with a *.)",
          },
          "status" => {
            desc: "Show the status of all the services.",
            arity: 2,
          },
          "tail" => {
            desc: "Watch the service logs of all enabled services.",
            arity: 2,
          },
          "start" => {
            desc: "Start services if they are down, and restart them if they stop.",
            arity: 2,
          },
          "stop" => {
            desc: "Stop the services, and do not restart them.",
            arity: 2,
          },
          "restart" => {
            desc: "Stop the services if they are running, then start them again.",
            arity: 2,
          },
          "once" => {
            desc: "Start the services if they are down. Do not restart them if they stop.",
            arity: 2,
          },
          "hup" => {
            desc: "Send the services a HUP.",
            arity: 2,
          },
          "term" => {
            desc: "Send the services a TERM.",
            arity: 2,
          },
          "int" => {
            desc: "Send the services an INT.",
            arity: 2,
          },
          "kill" => {
            desc: "Send the services a KILL.",
            arity: 2,
          },
          "graceful-kill" => {
            desc: "Attempt a graceful stop, then SIGKILL the entire process group.",
            arity: 2,
          },
          "usr1" => {
            desc: "Send the services a USR1.",
            arity: 2,
          },
          "usr2" => {
            desc: "Send the services a USR2.",
            arity: 2,
          },
        },
      }
      @category_command_map.merge!(service_command_map) if service_commands?
    end

    def self.to_method_name(name)
      name.gsub(/-/, "_").to_sym
    end

    def to_method_name(name)
      Ctl.to_method_name(name)
    end

    SV_COMMAND_NAMES.each do |sv_cmd|
      define_method to_method_name(sv_cmd) do |*args|
        run_sv_command(*args)
      end
    end

    # merges category_command_map and command_map,
    # removing categories
    def get_all_commands_hash
      without_categories = {}
      category_command_map.each do |category, commands|
        without_categories.merge!(commands)
      end
      command_map.merge(without_categories)
    end

    def service_commands?
      @service_commands
    end

    def load_files(path)
      Dir["#{path}/*.rb"].each do |file|
        load_file(file)
      end
    end

    def load_file(filepath)
      eval(IO.read(filepath), nil, filepath, 1) # rubocop: disable Security/Eval
    end

    def add_command(name, description, arity = 1, &block)
      @command_map[name] = { desc: description, arity: arity }
      self.class.send(:define_method, to_method_name(name).to_sym) { |*args| block.call(*args) }
    end

    def add_command_under_category(name, category, description, arity = 1, &block)
      # add new category if it doesn't exist
      @category_command_map[category] ||= {}
      @category_command_map[category][name] = { desc: description, arity: arity }
      self.class.send(:define_method, to_method_name(name).to_sym) { |*args| block.call(*args) }
    end

    def add_global_pre_hook(name, &block)
      method_name = to_method_name("#{name}_global_pre_hook").to_sym
      @global_pre_hooks[name] = method_name
      self.class.send(:define_method, method_name, block)
    end

    def exit!(code)
      @force_exit = true
      code
    end

    def log(msg)
      fh_output.puts msg
    end

    def get_pgrp_from_pid(pid)
      ps = `which ps`.chomp
      `#{ps} -p #{pid} -o pgrp=`.chomp
    end

    def get_pids_from_pgrp(pgrp)
      pgrep = `which pgrep`.chomp
      `#{pgrep} -g #{pgrp}`.split(/\n/).join(" ")
    end

    def sigkill_pgrp(pgrp)
      pkill = `which pkill`.chomp
      run_command("#{pkill} -9 -g #{pgrp}")
    end

    def run_command(command)
      system(command)
      $?
    end

    def service_list(*args)
      get_all_services.each do |service_name|
        print "#{service_name}"
        print "*" if service_enabled?(service_name)
        print "\n"
      end
      exit! 0
    end

    def cleanup_procs_and_nuke(filestr, calling_method = nil)
      run_sv_command("stop")

      FileUtils.rm_f("/etc/init/#{name}-runsvdir.conf") if File.exist?("/etc/init/#{name}-runsvdir.conf")
      run_command("egrep -v '#{base_path}/embedded/bin/runsvdir-start' /etc/inittab > /etc/inittab.new && mv /etc/inittab.new /etc/inittab") if File.exist?("/etc/inittab")
      run_command("kill -1 1")

      @backup_dir = Time.now.strftime("/root/#{name}-cleanse-%FT%R")

      FileUtils.mkdir_p("/root") unless File.exist?("/root")
      FileUtils.rm_rf(backup_dir)
      FileUtils.cp_r(etc_path, backup_dir) if File.exist?(etc_path)
      run_command("rm -rf #{filestr}")
      graceful_kill

      log "Terminating processes running under application users. This will take a few seconds."
      run_command("pkill -HUP -u #{kill_users.join(",")}") if kill_users.length > 0
      run_command("pkill -HUP -f 'runsvdir -P #{service_path}'")
      sleep 3
      run_command("pkill -TERM -u #{kill_users.join(",")}") if kill_users.length > 0
      run_command("pkill -TERM -f 'runsvdir -P #{service_path}'")
      sleep 3
      run_command("pkill -KILL -u #{kill_users.join(",")}") if kill_users.length > 0
      run_command("pkill -KILL -f 'runsvdir -P #{service_path}'")

      get_all_services.each do |die_daemon_die|
        run_command("pkill -KILL -f 'runsv #{die_daemon_die}'")
      end
      log "Your config files have been backed up to #{backup_dir}."
      exit! 0
    end

    def uninstall(*args)
      cleanup_procs_and_nuke("/tmp/opt")
    end

    def scary_cleanse_warning(*args)
      just_do_it = args.include?("yes")
      with_external = ARGV.include?("--with-external")
      log <<EOM
    *******************************************************************
    * * * * * * * * * * *       STOP AND READ       * * * * * * * * * *
    *******************************************************************
    This command will delete *all* local configuration, log, and
    variable data associated with #{display_name}.
EOM
      if with_external
        log <<EOM
    This will also delete externally hosted #{display_name} data.
    This means that any service you have configured as 'external'
    will have any #{display_name} permanently deleted.
EOM
      elsif not external_services.empty?
        log <<EOM

    Important note: If you also wish to delete externally hosted #{display_name}
    data, please hit CTRL+C now and run '#{exe_name} cleanse --with-external'
EOM
      end

      unless just_do_it
        data = with_external ? "local, and remote data" : "and local data"
        log <<EOM

    You have 60 seconds to hit CTRL-C before configuration,
    logs, #{data} for this application are permanently
    deleted.
    *******************************************************************

EOM
        begin
          sleep 60
        rescue Interrupt
          log ""
          exit 0
        end
      end
    end

    def cleanse(*args)
      scary_cleanse_warning(*args)
      cleanup_procs_and_nuke("#{service_path}/* /tmp/opt #{data_path} #{etc_path} #{log_path}", "cleanse")
    end

    def get_all_services_files
      Dir[File.join(sv_path, "*")]
    end

    def get_all_services
      get_all_services_files.map { |f| File.basename(f) }.sort
    end

    def service_enabled?(service_name)
      File.symlink?("#{service_path}/#{service_name}")
    end

    def run_sv_command(sv_cmd, service = nil)
      exit_status = 0
      sv_cmd = "1" if sv_cmd == "usr1"
      sv_cmd = "2" if sv_cmd == "usr2"
      if service
        exit_status += run_sv_command_for_service(sv_cmd, service)
      else
        get_all_services.each do |service_name|
          exit_status += run_sv_command_for_service(sv_cmd, service_name) if global_service_command_permitted(sv_cmd, service_name)
        end
      end
      exit! exit_status
    end

    # run an sv command for a specific service name
    def run_sv_command_for_service(sv_cmd, service_name)
      if service_enabled?(service_name)
        status = run_command("#{base_path}/init/#{service_name} #{sv_cmd}")
        status.exitstatus
      else
        log "#{service_name} disabled" if sv_cmd == "status" && verbose
        0
      end
    end

    # if we're running a global service command (like p-c-c status)
    # across all of the services, there are certain cases where we
    # want to prevent services files that exist in the service
    # directory from being activated. This method is the logic that
    # blocks those services
    def global_service_command_permitted(sv_cmd, service_name)
      # For services that have been removed, we only want to
      # them to respond to the stop command. They should not show
      # up in status, and they should not be started.
      if removed_services.include?(service_name)
        return sv_cmd == "stop"
      end

      # For keepalived, we only want it to respond to the status
      # command when running global service commands like p-c-c start
      # and p-c-c stop
      if service_name == "keepalived"
        return sv_cmd == "status"
      end

      # If c-s-c status is called, check to see if the service
      # is hidden supposed to be hidden from the status results
      # (mover for example should be hidden).
      if sv_cmd == "status"
        return !(hidden_services.include?(service_name))
      end

      # All other services respond normally to p-c-c * commands
      true
    end

    # removed services are configured via the attributes file in
    # the main omnibus cookbook
    def removed_services
      # in the case that there is no running_config (the config file does
      # not exist), we know that this will be a new server, and we don't
      # have to worry about pre-upgrade services hanging around. We can safely
      # return an empty array when running_config is nil
      running_package_config["removed_services"] || []
    end

    # hidden services are configured via the attributes file in
    # the main omnibus cookbook
    #
    # hidden services are services that we do not want to show up in
    # c-s-c status.
    def hidden_services
      # in the case that there is no running_config (the config file does
      # not exist), we don't want to return nil, just return an empty array.
      # worse result with doing that is services that we don't want to show up in
      # c-s-c status will show up.
      running_package_config["hidden_services"] || []
    end

    # translate the name from the config to the package name.
    # this is a special case for the private-chef package because
    # it is configured to use the name and directory structure of
    # 'opscode', not 'private-chef'
    def package_name
      case @name
      when "opscode"
        "private-chef"
      else
        @name
      end
    end

    # returns nil when chef-server-running.json does not exist
    def running_config
      fname = "#{etc_path}/#{::ChefUtils::Dist::Server::SERVER}-running.json"
      @running_config ||= if File.exist?(fname)
                            JSON.parse(File.read(fname))
                          end
    end

    # Helper function that returns the hash of config hashes that have the key 'external' : true
    # in the running config. If none exist it will return an empty hash.
    def external_services
      @external_services ||= running_package_config.select { |k, v| v.class == Hash and v["external"] == true }
    end

    # Helper function that returns true if an external service entry exists for
    # the named service
    def service_external?(service)
      return false if service.nil?

      external_services.key? service
    end

    # Gives package config from the running_config.
    # If there is no running config or if package_name doens't
    # reference a valid key, this will return an empty hash
    def running_package_config
      if (cfg = running_config)
        cfg[package_name.gsub(/-/, "_")] || {}
      else
        {}
      end
    end

    # This returns running_config[package][service].
    #
    # If there is no running_config or is no matching key
    # it will return nil.
    def running_service_config(service)
      running_package_config[service]
    end

    def remove_old_node_state
      node_cache_path = "#{base_path}/embedded/nodes/"
      status = run_command("rm -rf #{node_cache_path}")
      unless status.success?
        log "Could not remove cached node state!"
        exit 1
      end
    end

    def run_chef(attr_location, args = "")
      if @verbose
        log_level = "-l debug"
      elsif @quiet
        # null formatter is awfully quiet, so let them know we're doing something.
        log "Reconfiguring #{display_name}."
        log_level = "-l fatal -F null"
      else
        log_level = ""
      end
      remove_old_node_state
      cmd = "#{base_path}/embedded/bin/chef-client #{log_level} -z -c #{base_path}/embedded/cookbooks/solo.rb -j #{attr_location}"
      cmd += " #{args}" unless args.empty?
      run_command(cmd)
    end

    def show_config(*args)
      status = run_chef("#{base_path}/embedded/cookbooks/show-config.json", "-l fatal -F null")
      exit! status.success? ? 0 : 1
    end

    def reconfigure(*args)
      # args being passed to this command does not include the ones that are
      # starting with "-". See #is_option? method. If it is starting with "-"
      # then it is treated as a option and we need to look for them in ARGV.
      check_license_acceptance(ARGV.include?("--accept-license"))

      status = run_chef("#{base_path}/embedded/cookbooks/dna.json")
      if status.success?
        log "#{display_name} Reconfigured!"
        exit! 0
      else
        exit! 1
      end
    end

    def check_license_acceptance(override_accept = false)
      license_guard_file_path = File.join(data_path, ".license.accepted")

      # If the project does not have a license we do not have
      # any license to accept.
      return unless File.exist?(project_license_path)

      unless File.exist?(license_guard_file_path)
        if override_accept || ask_license_acceptance
          FileUtils.mkdir_p(data_path)
          FileUtils.touch(license_guard_file_path)
        else
          log "Please accept the software license agreement to continue."
          exit(1)
        end
      end
    end

    def ask_license_acceptance
      log "To use this software, you must agree to the terms of the software license agreement."

      unless STDIN.tty?
        log "Please view and accept the software license agreement, or pass --accept-license."
        exit(1)
      end

      log "Press any key to continue."
      user_input = STDIN.getch
      user_input << STDIN.getch while STDIN.ready?
      # No need to check for user input

      system("less #{project_license_path}")

      loop do
        log "Type 'yes' to accept the software license agreement, or anything else to cancel."

        user_input = STDIN.gets.chomp.downcase
        case user_input
        when "yes"
          return true
        else
          log "You have not accepted the software license agreement."
          return false
        end
      end
    end

    def project_license_path
      File.join(base_path, "LICENSE")
    end

    def tail(*args)
      # find /var/log -type f -not -path '*/sasl/*' | grep -E -v '(lock|@|tgz|gzip)' | xargs tail --follow=name --retry
      command = "find -L #{log_path}"
      command << "/#{args[1]}" if args[1]
      command << " -type f"
      command << log_path_exclude.map { |path| " -not -path '#{path}'" }.join(" ")
      command << " | grep -E -v '#{log_exclude}' | xargs tail --follow=name --retry"

      system(command)
    end

    def is_integer?(string)
      return true if Integer(string) rescue false
    end

    def graceful_kill(*args)
      service = args[1]
      exit_status = 0
      get_all_services.each do |service_name|
        next if !service.nil? && service_name != service

        if service_enabled?(service_name)
          pidfile = "#{sv_path}/#{service_name}/supervise/pid"
          pid = File.read(pidfile).chomp if File.exist?(pidfile)
          if pid.nil? || !is_integer?(pid)
            log "could not find #{service_name} runit pidfile (service already stopped?), cannot attempt SIGKILL..."
            status = run_command("#{base_path}/init/#{service_name} stop")
            exit_status = status.exitstatus if exit_status == 0 && !status.success?
            next
          end
          pgrp = get_pgrp_from_pid(pid)
          if pgrp.nil? || !is_integer?(pgrp)
            log "could not find pgrp of pid #{pid} (not running?), cannot attempt SIGKILL..."
            status = run_command("#{base_path}/init/#{service_name} stop")
            exit_status = status.exitstatus if exit_status == 0 && !status.success?
            next
          end
          run_command("#{base_path}/init/#{service_name} stop")
          pids = get_pids_from_pgrp(pgrp)
          unless pids.empty?
            log "found stuck pids still running in process group: #{pids}, sending SIGKILL" unless pids.empty?
            sigkill_pgrp(pgrp)
          end
        else
          log "#{service_name} disabled, not stopping"
          exit_status = 1
        end
      end
      exit! exit_status
    end

    def help(*args)
      log "#{exe_name}: command (subcommand)\n"
      command_map.keys.sort.each do |command|
        log command
        log "  #{command_map[command][:desc]}"
      end
      category_command_map.each do |category, commands|
        # Remove "-" and replace with spaces in category and capalize for output
        category_string = category.gsub("-", " ").split.map(&:capitalize).join(" ")
        log "#{category_string} Commands:\n"

        # Print each command in this category
        commands.keys.sort.each do |command|
          log "  #{command}"
          log "    #{commands[command][:desc]}"
        end
      end
      # Help is not an error so exit with 0.  In cases where we display help as a result of an error
      # the framework will handle setting proper exit code.
      exit! 0
    end

    # Set global options and remove them from the args list we pass
    # into commands.
    def parse_options(args)
      args.select do |option|
        case option
        when "--quiet", "-q"
          @quiet = true
          false
        when "--verbose", "-v"
          @verbose = true
          false
        end
      end
    end

    # If it begins with a '-', it is an option.
    def is_option?(arg)
      arg && arg[0] == "-"
    end

    # retrieves the commmand from either the command_map
    # or the category_command_map, if the command is not found
    # return nil
    def retrieve_command(command_to_run)
      if command_map.key?(command_to_run)
        command_map[command_to_run]
      else
        command = nil
        category_command_map.each do |category, commands|
          command = commands[command_to_run] if commands.key?(command_to_run)
        end
        # return the command, or nil if it wasn't found
        command
      end
    end

    # Previously this would exit immediately with the provided
    # exit code; however this would prevent post-run hooks from continuing
    # Instead, we'll just track whether a an exit was requested and use that
    # to determine how we exit from 'run'
    def run(args)
      # Ensure Omnibus related binaries are in the PATH
      ENV["PATH"] = [File.join(base_path, "bin"),
                     File.join(base_path, "embedded", "bin"),
                     ENV["PATH"]].join(":")

      command_to_run = args[0]

      ## when --help is run as the command itself, we need to strip off the
      ## `--` to ensure the command maps correctly.
      if command_to_run == "--help"
        command_to_run = "help"
      end

      # This piece of code checks if the argument is an option. If it is,
      # then it sets service to nil and adds the argument into the options
      # argument. This is ugly. A better solution is having a proper parser.
      # But if we are going to implement a proper parser, we might as well
      # port this to Thor rather than reinventing Thor. For now, this preserves
      # the behavior to complain and exit with an error if one attempts to invoke
      # a pcc command that does not accept an argument. Like "help".
      options = args[2..-1] || []
      if is_option?(args[1])
        options.unshift(args[1])
        service = nil
      else
        service = args[1]
      end

      # returns either hash content of command or nil
      command = retrieve_command(command_to_run)
      if command.nil?
        log "I don't know that command."
        if args.length == 2
          log "Did you mean: #{exe_name} #{service} #{command_to_run}?"
        end
        help
        Kernel.exit 1
      end

      if args.length > 1 && command[:arity] != 2
        log "The command #{command_to_run} does not accept any arguments"
        Kernel.exit 2
      end

      parse_options options
      @force_exit = false
      exit_code = 0

      run_global_pre_hooks

      # Filter args to just command and service. If you are loading
      # custom commands and need access to the command line argument,
      # use ARGV directly.
      actual_args = [command_to_run, service].reject(&:nil?)
      if command_pre_hook(*actual_args)
        method_to_call = to_method_name(command_to_run)
        begin
          ret = send(method_to_call, *actual_args)
        rescue SystemExit => e
          @force_exit = true
          ret = e.status
        end
        command_post_hook(*actual_args)
        exit_code = ret unless ret.nil?
      else
        exit_code = 8
        @force_exit = true
      end

      if @force_exit
        Kernel.exit exit_code
      else
        exit_code
      end
    end

    def run_global_pre_hooks
      @global_pre_hooks.each do |hook_name, method_name|

        send(method_name)
      rescue => e
        $stderr.puts("Global pre-hook '#{hook_name}' failed with: '#{e.message}'")
        exit(1)

      end
    end

    # Below are some basic command hooks that do the right  thing
    # when a service is configured as external via [package][service

    # If a command has a pre-hook defined we will run it.
    # Otherwise, if it is a run-sv command and the service it refers to
    # is an external service, we will show an error since we
    # can't control external services from here.
    #
    # If any pre-hook returns false, it will prevent execution of the command
    # and exit the command with exit code 8.
    def command_pre_hook(*args)
      command = args.shift
      method = to_method_name("#{command}_pre_hook")
      if respond_to?(method)
        send(method, *args)
      else
        return true if args.empty?

        if SV_COMMAND_NAMES.include? command
          if service_external? args[0]
            log error_external_service(command, args[0])
            return false
          end
        end
        true
      end
    end

    # Executes after successful completion of a command
    # If a post-hook provides a numeric return code, it will
    # replace the return/exit of the original command
    def command_post_hook(*args)
      command = args.shift
      method = to_method_name("#{command}_post_hook")
      if respond_to?(method)
        send(method, *args)
      end
    end

    # If we're listing status for all services and have external
    # services to show, we'll include an output header to show that
    # we're reporting internal services
    def status_pre_hook(service = nil)
      log_internal_service_header if service.nil?
      true
    end

    # Status gets its own hook because each externalized service will
    # have its own things to do in order to report status.
    # As above, we may also include an output header to show that we're
    # reporting on external services.
    #
    # Your callback for this function should be in the form
    # 'external_status_#{service_name}(detail_level)
    # where detail_level is :sparse|:verbose
    # :sparse is used when it's a summary service status list, eg
    # "$appname-ctl status"
    # :verbose is used when the specific service has been named, eg
    # "$appname-ctl status postgresql"
    def status_post_hook(service = nil)
      if service.nil?
        log_external_service_header
        external_services.each_key do |service_name|
          status = send(to_method_name("external_status_#{service_name}"), :sparse)
          log status
        end
      else
        # Request verbose status if the service is asked for by name.
        if service_external?(service)
          status = send(to_method_name("external_status_#{service}"), :verbose)
          log status
        end
      end
    end

    # Data cleanup requirements for external services aren't met by the standard
    # 'nuke /var/opt' behavior - this hook allows each service to perform its own
    # 'cleanse' operations.
    #
    # Your callback for this function should be in the
    # form 'external_cleanup_#{service_name}(do_clean)
    # where do_cliean is true if the delete should actually be
    # performed, and false if it's expected to inform the user how to
    # perform the data cleanup without doing any cleanup itself.
    def cleanse_post_hook(*args)
      external_services.each_key do |service_name|
        perform_delete = ARGV.include?("--with-external")
        if perform_delete
          log "Deleting data from external service: #{service_name}"
        end
        send(to_method_name("external_cleanse_#{service_name}"), perform_delete)
      end
    end

    # Add some output headers if we have external services enabled
    def service_list_pre_hook
      log_internal_service_header
      true
    end

    # Capture external services in the output list as well.
    def service_list_post_hook
      log_external_service_header
      external_services.each  do |name, settings|
        log " >  #{name} on #{settings["vip"]}"
      end
    end

    def error_external_service(command, service)
      <<EOM
-------------------------------------------------------------------
The service #{service} is running externally and cannot be managed
vi chef-server-ctl.  Please log into #{external_services[service]["vip"]}
to manage it directly.
-------------------------------------------------------------------
EOM
    end

    def format_multiline_message(indent, message)
      if message.class == String
        message = message.split("\n")
      end
      spaces = " " * indent
      message.map! { |line| "#{spaces}#{line.strip}" }
      message.join("\n")
    end

    def log_internal_service_header
      # Don't decorate output unless we have
      # external services to report on.
      return if external_services.empty?

      log "-------------------"
      log " Internal Services "
      log "-------------------"
    end

    def log_external_service_header
      return if external_services.empty?

      log "-------------------"
      log " External Services "
      log "-------------------"
    end
  end
end
