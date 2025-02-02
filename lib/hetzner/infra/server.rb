# frozen_string_literal: true

require 'active_support'

module Hetzner
  class Server
    def initialize(hetzner_client:, cluster_name:)
      @hetzner_client = hetzner_client
      @cluster_name = cluster_name
    end

    def create(location:, instance_type:, instance_id:, firewall_id:, network_id:, ssh_key_id:, default_ssh_key_ids:, placement_group_id:, image:, additional_packages: [], additional_post_create_commands: [], **additional_server_settings)
      @location = location
      @instance_type = instance_type
      @instance_id = instance_id
      @firewall_id = firewall_id
      @network_id = network_id
      @ssh_key_id = ssh_key_id
      @default_ssh_key_ids = default_ssh_key_ids
      @placement_group_id = placement_group_id
      @image = image
      @additional_packages = additional_packages
      @additional_post_create_commands = additional_post_create_commands
      @additional_server_settings = additional_server_settings

      puts

      if (server = find_server(server_name))
        puts "Server #{server_name} already exists, skipping."
        puts
        return server
      end

      puts "Creating server #{server_name}..."

      server, error = make_request
      if (server.present?)
        puts "...server #{server_name} created."
        puts

        return server
      else
        puts "Error creating server #{server_name}. Response details below:"
        puts

        p error
        return nil
      end
    end

    def ssh_key_ids
      @ssh_key_ids ||= [@ssh_key_id] + @default_ssh_key_ids
    end

    def delete(server_name:)
      if (server = find_server(server_name))
        puts "Deleting server #{server_name}..."
        hetzner_client.delete '/servers', server['id']
        puts "...server #{server_name} deleted."
      else
        puts "Server #{server_name} no longer exists, skipping."
      end
    end

    private

    attr_reader :hetzner_client, :cluster_name, :location, :instance_type, :instance_id, :firewall_id, :network_id, :placement_group_id, :image, :additional_packages, :additional_post_create_commands, :additional_server_settings

    def find_server(server_name)
      hetzner_client.get('/servers?sort=created:desc')['servers'].detect { |network| network['name'] == server_name }
    end

    def user_data
      <<~YAML
        #cloud-config
        packages: [#{packages}]
        runcmd:
        #{post_create_commands}
      YAML
    end

    def server_name
      @server_name ||= "#{cluster_name}-#{instance_type}-#{instance_id}"
    end

    def server_config
      @server_config ||= {
        name: server_name,
        location: location,
        image: image,
        firewalls: [
          { firewall: firewall_id },
        ],
        networks: [
          network_id,
        ],
        server_type: instance_type,
        ssh_keys: ssh_key_ids,
        user_data: user_data,
        labels: {
          cluster: cluster_name,
          role: (server_name =~ /master/ ? 'master' : 'worker'),
        },
        placement_group: placement_group_id,
        **additional_server_settings
      }
    end

    def make_request
      response = hetzner_client.post('/servers', server_config)
      response_body = response.body

      s = JSON.parse(response_body)['server']

      if (s.present?)
        return s, response
      else
        return nil, response
      end
    end

    def post_create_commands
      commands = [
        'crontab -l > /etc/cron_bkp',
        'echo "@reboot echo true > /etc/ready" >> /etc/cron_bkp',
        'crontab /etc/cron_bkp',
        'sed -i \'s/[#]*PermitRootLogin yes/PermitRootLogin prohibit-password/g\' /etc/ssh/sshd_config',
        'sed -i \'s/[#]*PasswordAuthentication yes/PasswordAuthentication no/g\' /etc/ssh/sshd_config',
        'systemctl restart sshd',
        'systemctl stop systemd-resolved',
        'systemctl disable systemd-resolved',
        'rm /etc/resolv.conf',
        'echo \'nameserver 1.1.1.1\' > /etc/resolv.conf',
        'echo \'nameserver 1.0.0.1\' >> /etc/resolv.conf',
      ]

      commands += additional_post_create_commands if additional_post_create_commands

      commands << 'shutdown -r now' if commands.grep(/shutdown|reboot/).grep_v(/@reboot/).empty?

      "  - #{commands.join("\n  - ")}"
    end

    def packages
      packages = %w[fail2ban wireguard]
      packages += additional_packages if additional_packages
      "'#{packages.join("', '")}'"
    end
  end
end
