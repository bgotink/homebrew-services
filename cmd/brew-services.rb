#!/usr/bin/env ruby -w

# brew-services(1) - Easily start and stop formulae via launchctl
# ===============================================================
#
# ## SYNOPSIS
#
# [<sudo>] 'brew services' 'list'<br>
# [<sudo>] 'brew services' 'restart' <formula><br>
# [<sudo>] 'brew services' 'start' <formula> [<plist>]<br>
# [<sudo>] 'brew services' 'stop' <formula><br>
# [<sudo>] 'brew services' 'cleanup'<br>
#
# ## DESCRIPTION
#
# Integrates homebrew formulae with MacOS X' 'launchctl' manager. Services
# can either be added to '/Library/LaunchDaemons' or '~/Library/LaunchAgents'.
# Basically items added to '/Library/LaunchDaemons' are started at boot,
# those in '~/Library/LaunchAgents' at login.
#
# When started with 'sudo' it operates on '/Library/LaunchDaemons', else
# in the user space.
#
# Basically on 'start' the plist file is generated and written to a 'Tempfile',
# then copied to the launch path (existing plists are overwritten).
#
# ## OPTIONS
#
# To access everything quickly, some aliases have been added:
#
#  * 'rm':
#    Shortcut for 'cleanup', because that's basically whats being done.
#
#  * 'ls':
#    Because 'list' is too much to type :)
#
#  * 'reload', 'r':
#    Alias for 'restart', which gracefully restarts selected service.
#
#  * 'load', 's':
#    Alias for 'start', guess what it does...
#
#  * 'unload', 'term', 't':
#    Alias for 'stop', stops and unloads selected service.
#
# ## SYNTAX
#
# Several existing formulae (like mysql, nginx) already write custom plist
# files to the formulae prefix. Most of these implement '#startup_plist'
# which then in turn returns a neat-o plist file as string.
#
# 'brew services' operates on '#startup_plist' as well and requires
# supporting formulae to implement it. This method should either string
# containing the generated XML file, or return a 'Pathname' instance which
# points to a plist template, or a hash like:
#
#    { :url => "https://gist.github.com/raw/534777/63c4698872aaef11fe6e6c0c5514f35fd1b1687b/nginx.plist.xml" }
#
# Some simple template parsing is performed, all variables like '{{name}}' are
# replaced by basically doing:
# 'formula.send('name').to_s if formula.respond_to?('name')', a bit like
# mustache. So any variable in the 'Formula' is available as template
# variable, like '{{var}}', '{{bin}}' usw.
#
# ## EXAMPLES
#
# Install and start service mysql at boot:
#
#     $ brew install mysql
#     $ sudo brew services start mysql
#
# Stop service mysql (when launched at boot):
#
#     $ sudo brew services stop mysql
#
# Start memcached at login:
#
#     $ brew install memcached
#     $ brew services start memcached
#
# List all running services for current user, and root:
#
#     $ brew services list
#     $ sudo brew services list
#
# ## BUGS
#
# 'brew-services.rb' might not handle all edge cases, though it tries
# to fix problems by running 'brew services cleanup'.
#
# ## COPYRIGHT
#
# Copyright (c) 2010 Lukas Westermann <lukas@at-point.ch>
# Copyright (c) 2014 Bram Gotink <bram@gotink.me>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
module ServicesCli
  class << self
    # Binary name.
    def bin; "brew services" end

    # Path to launchctl binary.
    def launchctl; which("launchctl") end

    # Wohoo, we are root dude!
    def root?; Process.uid == 0 end

    # Current user, i.e. owner of 'HOMEBREW_CELLAR'.
    def user
      @user ||= %x{/usr/bin/stat -f '%Su' #{HOMEBREW_CELLAR} 2>/dev/null}.chomp || %x{/usr/bin/whoami}.chomp
    end

    # Run at boot.
    def boot_path; Pathname.new("/Library/LaunchDaemons") end

    # Run at login.
    def user_path; Pathname.new(ENV['HOME'] + '/Library/LaunchAgents') end

    # If root returns 'boot_path' else 'user_path'.
    def path
      if root?
        boot_path
      else
        user_path
      end
    end

    # Find all currently running services via launchctl list
    def running;
      %x{#{launchctl} list | grep homebrew.mxcl}
        .chomp
        .split("\n")
        .map { |svc| $1 if svc =~ /(homebrew\.mxcl\..+)\z/ }
        .compact
    end

    # Check if running as homebrew and load required libraries et al.
    def homebrew!
      abort("Runtime error: homebrew is required, please start via '#{bin} ...'") unless defined?(HOMEBREW_LIBRARY_PATH)

      %w{fileutils pathname tempfile formula}.each { |req| require(req) }
    end

    # Print usage and 'exit(...)' with supplied exit code, if code
    # is set to 'false', then exit is ignored.
    def usage(code = 0)
      puts "usage: [sudo] #{bin} [--help] <command> [<formula>...]"
      puts
      puts "Small wrapper around 'launchctl' for supported formulae, commands available:"
      puts "   cleanup Get rid of stale services and unused plists"
      puts "   list    List all services managed by '#{bin}'"
      puts "   restart Gracefully restart selected services"
      puts "   start   Start selected services"
      puts "   stop    Stop selected services"
      puts
      puts "Options, sudo and paths:"
      puts
      puts "  sudo   When run as root, operates on #{boot_path} (run at boot!)"
      puts "  Run at boot:  #{boot_path}"
      puts "  Run at login: #{user_path}"
      puts
      exit(code) unless code == false
      true
    end

    def check_no_formulae
      if @args.length > 0
        ofail "#{bin} #{@cmd} doesn't expect any formulae"
        usage(1)
      end
    end

    def check_requires_formulae
      if @args.length == 0
        ofail "#{bin} #{@cmd} requires at least one formula as argument"
        usage(1)
      end
    end

    # Run and start the command loop.
    def run!
      # check if in homebrew context
      homebrew!

      # print usage if needed
      usage if ARGV.empty? || ARGV.include?('help') || ARGV.include?('--help') || ARGV.include?('-h')

      # parse arguments
      @args = ARGV.named.map { |arg| arg.include?("/") ? arg : arg.downcase }
      @cmd = @args.shift

      # dispatch commands and aliases
      case @cmd
        when 'cleanup', 'clean', 'cl', 'rm'
          cleanup
        when 'list', 'ls'
          list
        when 'restart', 'relaunch', 'reload', 'r'
          restart
        when 'start', 'launch', 'load', 's', 'l'
          start
        when 'stop', 'unload', 'terminate', 'term', 't', 'u'
          stop
        else
          ofail "Unknown command '#{@cmd}'"
          usage(1)
      end
    end

    # List all running services with PID and status and path to plist file, if available
    def list
      check_no_formulae

      if running.empty?
        opoo "No %s services controlled by '#{bin}' running..." % [root? ? 'root' : 'user-level']
        return
      end

      # print a header
      puts "%-15.15s %-10.10s %-10.10s %s" % ['Name', 'Status', 'PID', 'Plist path']

      # print a line for each process
      running.each do |label|
        if service = Service.from(label)
          if !service.dest.file?
            status = 'stale'
            color = Tty.red
          else
            status = 'started'
            color = Tty.white
          end

          puts "%-15.15s #{color}%-10.10s#{Tty.reset} %-10.10s %s" % [
            service.name,
            status,
            service.pid ? service.pid.to_s : '-',
            service.dest.file? ? service.dest.to_s.gsub(ENV['HOME'], '~') : label
          ]
        else
          puts "%-15.15s #{Tty.red}%-10.10s#{Tty.reset} %-10.10s #{label}" % ['?', 'unknown', '-']
        end
      end
    end

    # Kill services without plist file and remove unused plists
    def cleanup
      check_no_formulae

      cleaned = false

      # 1. kill services which have no plist file
      running.each do |label|
        if service = Service.from(label)
          if not service.dest.file?
            puts "%-15.15s #{Tty.white}stale#{Tty.reset} => killing service..." % service.name
            service.kill
            cleaned = true
          end
        else
          opoo "Service #{label} not managed by '#{bin}' => skipping"
        end
      end

      # 2. remove unused plist files
      Dir[path + 'homebrew.mxcl.*.plist'].each do |file|
        unless running.include? File.basename(file).sub(/\.plist$/i, '')
          puts "Removing unused plist #{file}"
          FileUtils.rm file
          cleaned = true
        end
      end

      ohai "All #{root? ? 'root' : 'user-level'} services OK, nothing cleaned..." unless cleaned
    end

    def do_for_each_service
      check_requires_formulae

      @args.each do |name|
        service = Service.from name

        if service.nil?
          odie "Unknown service '#{name}'"
          return
        end

        yield service
      end
    end

    # Restart all listed services
    def restart
      do_for_each_service { |service| service.restart }
    end

    # Start all listed services
    def start
      do_for_each_service { |service| service.start }
    end

    # Stop all listed services
    def stop
      do_for_each_service { |service| service.stop }
    end
  end
end

# Wraps a formula with service-specific methods, e.g. start, stop, loaded? etc.
class Service
  # Create a new 'Service' instance from either a path or label.
  def self.from(path_or_label)
    new Formula.factory Formula.canonical_name path_or_label
  rescue
    return nil unless path_or_label =~ /homebrew\.mxcl\.([^\.]+)(\.plist)?\z/

    new Formula.factory Formula.canonical_name $1 rescue nil
  end

  attr_reader :name

  # checks whether the function is loaded

  def loaded?
    ServicesCli.running.include? label
  end

  # starts, stops, restarts, kills the service

  def start(custom_plist = nil)
    odie "Service '#{name}' already started" if loaded?

    if not custom_plist.nil?
      if custom_plist =~ %r{\Ahttps?://.+}
        custom_plist = { :url => custom_plist }
      elsif File.exist?(custom_plist)
        custom_plist = Pathname.new(custom_plist)
      else
        odie "#{custom_plist} is not a url or exising file"
      end
    end

    odie "Formula '#{name}' not installed, #plist not implemented or no plist file found" if custom_plist.nil? and not plist?

    temp = Tempfile.new label
    temp << generate_plist(custom_plist)
    temp.flush

    FileUtils.rm dest if dest.exist?
    FileUtils.cp temp.path, dest

    # clear tempfile
    temp.close

    safe_system ServicesCli.launchctl, "load", "-w", dest.to_s
    if $?.to_i != 0
      odie "Failed to start '#{name}'"
    else
      ohai "Successfully started '#{name}' as #{label}"
    end
  end

  def stop
    if not loaded?
      # get rid of installed plist anyway, dude
      FileUtils.rm dest if dest.exist?

      odie "Service '#{name}' was not running"
    end

    if dest.exist?
      puts "Stopping '#{name}'... (might take a while)"

      safe_system ServicesCli.launchctl, "unload", "-w", dest.to_s

      if $?.to_i != 0
        odie "Failed to stop '#{name}'"
      else
        ohai "Successfully stopped '#{name}' via #{label}"
      end
    else
      puts "Stopping stale service '#{name}' ... (might take a while)"
      kill
    end

    FileUtils.rm dest if dest.exist?
  end

  def restart
    stop if loaded?
    start
  end

  # Kill service without plist file by issuing a 'launchctl remove' command
  def kill
    safe_system ServicesCli.launchctl, "remove", label

    odie("Failed to remove '#{name}', try again?") unless $?.to_i == 0

    while loaded?
      puts "  ...checking status"
      sleep(5)
    end

    ohai "Successfully stopped '#{name}' via #{label}"
  end

  # Get current PID of daemon process from launchctl.
  def pid
    status = %x{#{ServicesCli.launchctl} list | grep #{label} 2>/dev/null}.chomp
    return $1.to_i if status =~ /\A([\d]+)\s+.+#{label}\z/
  end

  # Path to destination plist, if run as root it's in 'boot_path', else 'user_path'.
  def dest
    if ServicesCli.root?
      ServicesCli.boot_path
    else
      ServicesCli.user_path
    end + "#{label}.plist"
  end

  private

  # Access the 'Formula' instance
  attr_reader :formula, :label, :plist

  # Initialize new 'Service' instance with supplied formula.
  def initialize(formula)
    @formula = formula

    @name = formula.name

    # the plist name
    @label = formula.plist_name

    # the full plist path
    @plist = formula.plist_path
  end

  # Returns 'true' if formula implements #plist or file exists.
  def plist?; formula.installed? and (plist.file? or formula.respond_to?(:plist)) end

  # Generate that plist file, dude.
  def generate_plist(data = nil)
    data ||= plist.file? ? plist : formula.plist

    # support files and URLs
    if data.respond_to?(:file?) and data.file?
      data = data.read
    elsif data.respond_to?(:keys) and data.keys.include?(:url)
      require 'open-uri'
      data = open(data).read
    end

    # replace "template" variables and ensure label is always, always homebrew.mxcl.<formula>
    data = data.to_s.
      gsub(/\{\{([a-z][a-z0-9_]*)\}\}/i) { |m| formula.send($1).to_s if formula.respond_to?($1) }.
      gsub(%r{(<key>Label</key>\s*<string>)[^<]*(</string>)}, '\1' + label + '\2')

    # and force fix UserName, if necessary
    if ServicesCli.user != "root" && data =~ %r{<key>UserName</key>\s*<string>root</string>}
      data = data.gsub(%r{(<key>UserName</key>\s*<string>)[^<]*(</string>)}, '\1' + formula.startup_user + '\2')
    elsif ServicesCli.root? && ServicesCli.user != "root" && data !~ %r{<key>UserName</key>}
      data = data.gsub(%r{(</dict>\s*</plist>)}, "  <key>UserName</key><string>#{formula.startup_user}</string>\n\\1")
    end

    if ARGV.verbose?
      ohai "Generated plist for #{formula.name}:"
      puts "   " + data.gsub("\n", "\n   ")
      puts
    end

    data
  end
end

# Start the cli dispatch stuff.
#
ServicesCli.run!
