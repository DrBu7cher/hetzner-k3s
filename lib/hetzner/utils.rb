# frozen_string_literal: true

require 'childprocess'
require 'net/ssh/proxy/command'
require 'net/scp'

module Utils
  CMD_FILE_PATH = '/tmp/cli.cmd'

  def which(cmd)
    exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
    ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
      exts.each do |ext|
        exe = File.join(path, "#{cmd}#{ext}")
        return exe if File.executable?(exe) && !File.directory?(exe)
      end
    end
    nil
  end

  def write_file(path, content, append: false)
    File.open(path, append ? 'a' : 'w') { |file| file.write(content) }
  end

  def run(command, kubeconfig_path:)
    write_file CMD_FILE_PATH, <<-CONTENT
    set -euo pipefail
    #{command}
    CONTENT

    FileUtils.chmod('+x', CMD_FILE_PATH)

    begin
      process = ChildProcess.build('bash', '-c', CMD_FILE_PATH)
      process.io.inherit!
      process.environment['KUBECONFIG'] = kubeconfig_path
      process.environment['HCLOUD_TOKEN'] = ENV.fetch('HCLOUD_TOKEN', '')

      at_exit do
        process.stop
      rescue Errno::ESRCH, Interrupt
        # ignore
      end

      process.start
      process.wait
    rescue Interrupt
      puts 'Command interrupted'
      exit 1
    end
  end

  def wait_for_ssh(server)
    retries ||= 0

    Timeout.timeout(10) do
      server_name = server['name']

      puts "Waiting for server #{server_name} to be up..."

      loop do
        result = ssh(server, 'cat /etc/ready')
        break if result == 'true'
        sleep 3
      end

      puts "...server #{server_name} is now up."
    end
  rescue Errno::ENETUNREACH, Errno::EHOSTUNREACH, Timeout::Error, IOError, Errno::ECONNRESET
    retries += 1
    retry if retries <= 15
  end

  def ssh(server, command, scp_files: nil, print_output: false)
    debug = ENV.fetch('SSH_DEBUG', false)

    retries ||= 0

    output = ''

    params = { verify_host_key: (verify_host_key ? :always : :never) }

    params[:keys] = private_ssh_key_path && [private_ssh_key_path]
    params[:verbose] = :debug if debug

    if server['_jumphost']
      params[:proxy] = Net::SSH::Proxy::Command.new("ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p -p 22 root@#{server['_jumphost']} 2>/dev/null")
      target_ip = server.dig('private_net', 0, 'ip')
    else
      target_ip = server.dig('public_net', 'ipv4', 'ip')
    end

    Net::SSH.start(target_ip, 'root', params) do |session|
      scp_files.each do |from, to|
        session.scp.upload!("#{from}", "#{to}")
      end if scp_files
      session.exec!(command) do |_channel, _stream, data|
        output = "#{output}#{data}"
        puts data if print_output
      end
    end
    output.chop
  rescue Timeout::Error, IOError, Errno::EBADF => e
    puts "SSH CONNECTION DEBUG: #{e.message}" if debug
    retries += 1
    sleep 1
    retry if retries <= 15
  rescue Net::SSH::Disconnect => e
    puts "SSH CONNECTION DEBUG: #{e.message}" if debug
    retries += 1
    sleep 1
    retry if retries <= 15 || e.message =~ /Too many authentication failures/
  rescue Net::SSH::ConnectionTimeout, Errno::ECONNREFUSED, Errno::ENETUNREACH, Errno::EHOSTUNREACH => e
    puts "SSH CONNECTION DEBUG: #{e.message}" if debug
    retries += 1
    sleep 1
    retry if retries <= 15
  rescue Net::SSH::Proxy::ConnectError => e
    # this only occurs if a jumphost is set
    puts "SSH CONNECTION DEBUG: #{e.message}" if debug
    retries += 1
    sleep 1
    retry if retries <= 15
  rescue Net::SSH::AuthenticationFailed => e
    puts "SSH CONNECTION DEBUG: #{e.message}" if debug
    puts '\nCannot continue: SSH authentication failed. Please ensure that the private SSH key is correct.'
    exit 1
  rescue Net::SSH::HostKeyMismatch => e
    puts "SSH CONNECTION DEBUG: #{e.message}" if debug
    puts <<-MESSAGE
    Cannot continue: Unable to SSH into server with IP #{public_ip} because the existing fingerprint in the known_hosts file does not match that of the actual host key.\n
    This is due to a security check but can also happen when creating a new server that gets assigned the same IP address as another server you've owned in the past.\n
    If are sure no security is being violated here and you're just creating new servers, you can eiher remove the relevant lines from your known_hosts (see IPs from the cloud console) or disable host key verification by setting the option 'verify_host_key' to false in the configuration file for the cluster.
    MESSAGE
    exit 1
  end

  def verify_host_key
    @verify_host_key ||= configuration.fetch('verify_host_key', false)
  end
end
