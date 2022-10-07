# frozen_string_literal: true

require 'net/ssh'
require 'securerandom'
require 'base64'
require 'timeout'
require 'fileutils'

require_relative '../infra/client'
require_relative '../infra/firewall'
require_relative '../infra/network'
require_relative '../infra/ssh_key'
require_relative '../infra/server'
require_relative '../infra/load_balancer'
require_relative '../infra/placement_group'

require_relative '../kubernetes/client'

require_relative '../utils'

class Cluster
  include Utils

  def initialize(configuration:)
    @configuration = configuration
  end

  def create
    @cluster_name = configuration['cluster_name']
    @masters_config = configuration['masters']
    @worker_node_pools = find_worker_node_pools(configuration)
    @additional_server_settings = configuration['additional_server_settings']
    @masters_location = configuration['location']
    @servers = []
    @ssh_networks = configuration['ssh_allowed_networks']
    @api_networks = configuration['api_allowed_networks']
    @private_ssh_key_path = File.expand_path(configuration['private_ssh_key_path'])
    @public_ssh_key_path = File.expand_path(configuration['public_ssh_key_path'])
    @default_ssh_key_labels = configuration['default_ssh_key_labels']

    create_resources

    kubernetes_client.deploy(masters: masters, workers: workers, master_definitions: master_definitions_for_create, worker_definitions: workers_definitions_for_marking, default_ssh_keys: [k3s_ssh_key] + default_ssh_keys)
  end

  def delete
    @cluster_name = configuration['cluster_name']
    @kubeconfig_path = File.expand_path(configuration['kubeconfig_path'])
    @public_ssh_key_path = File.expand_path(configuration['public_ssh_key_path'])
    @masters_config = configuration['masters']
    @worker_node_pools = find_worker_node_pools(configuration)

    delete_resources
  end

  def upgrade(new_k3s_version:, config_file:)
    @cluster_name = configuration['cluster_name']
    @kubeconfig_path = File.expand_path(configuration['kubeconfig_path'])
    @new_k3s_version = new_k3s_version
    @config_file = config_file

    kubernetes_client.upgrade
  end

  private

  attr_accessor :servers

  attr_reader :configuration, :cluster_name, :kubeconfig_path,
              :masters_config, :worker_node_pools,
              :additional_server_settings, :load_balancer,
              :masters_location, :private_ssh_key_path, :public_ssh_key_path,
              :hetzner_token, :new_k3s_version,
              :config_file, :ssh_networks,
              :api_networks, :default_ssh_key_labels

  def find_worker_node_pools(configuration)
    configuration.fetch('worker_node_pools', [])
  end

  def belongs_to_cluster?(server)
    server.dig('labels', 'cluster') == cluster_name
  end

  def all_servers
    @all_servers ||= hetzner_client.get('/servers?sort=created:desc')['servers'].select do |server|
      belongs_to_cluster?(server) == true
    end
  end

  def masters
    @masters ||= all_servers.select { |server| server['name'] =~ /master\d+\Z/ }.sort { |a, b| a['name'] <=> b['name'] }
  end

  def workers
    @workers = all_servers.select { |server| server['name'] =~ /worker\d+\Z/ }.sort { |a, b| a['name'] <=> b['name'] }
  end

  def image
    configuration['image'] || 'ubuntu-20.04'
  end

  def additional_packages
    configuration['additional_packages'] || []
  end

  def additional_post_create_commands
    configuration['post_create_commands'] || []
  end

  def master_instance_type
    @master_instance_type ||= masters_config['instance_type']
  end

  def masters_count
    @masters_count ||= masters_config['instance_count']
  end

  def placement_group_id(pool_name = nil)
    @placement_groups ||= {}
    @placement_groups[pool_name || '__masters__'] ||= Hetzner::PlacementGroup.new(hetzner_client: hetzner_client, cluster_name: cluster_name, pool_name: pool_name).create
    @placement_groups[pool_name || '__masters__']['id']
  end

  def firewall
    @firewall ||= Hetzner::Firewall.new(hetzner_client: hetzner_client, cluster_name: cluster_name).create(high_availability: (masters_count > 1), ssh_networks: ssh_networks, api_networks: api_networks)
  end

  def network
    @network ||= Hetzner::Network.new(hetzner_client: hetzner_client, cluster_name: cluster_name, existing_network: existing_network).create(location: masters_location)
  end

  def k3s_ssh_key
    @k3s_ssh_key ||= Hetzner::SSHKey.new(hetzner_client: hetzner_client, cluster_name: cluster_name).create(public_ssh_key_path: public_ssh_key_path)
  end

  def default_ssh_keys
    return @default_ssh_keys unless @default_ssh_keys == nil
    tmp_ssh_key_arr = []

    default_ssh_key_labels.map do |label|
      key, value = label.first
      Hetzner::SSHKey.new(hetzner_client: hetzner_client, cluster_name: cluster_name).find_ssh_keys_by_label(key: key, value: value).each do |ssh_key|
        tmp_ssh_key_arr << ssh_key
      end
    end

    @default_ssh_keys = tmp_ssh_key_arr
  end

  def default_ssh_key_ids
    return @default_ssh_key_ids unless @default_ssh_key_ids == nil

    tmp_ssh_key_ids = []

    default_ssh_keys.each do |ssh_key|
      tmp_ssh_key_ids << ssh_key['id']
    end

    @default_ssh_key_ids = tmp_ssh_key_ids
  end

  def master_definitions_for_create
    definitions = []

    additional_master_settings = JSON.parse(JSON.generate(additional_server_settings))
    additional_master_settings['public_net']['enable_ipv4'] = false if masters_count > 1

    additional_first_master_settings = JSON.parse(JSON.generate(additional_server_settings))
    additional_first_master_settings['public_net']['enable_ipv4'] = true unless additional_master_settings['public_net'].nil? || additional_master_settings['public_net']['enable_ipv4'].nil?

    masters_count.times do |i|
      add = additional_master_settings
      add = additional_first_master_settings if i == 0
      definitions << {
        instance_type: master_instance_type,
        instance_id: "master#{i + 1}",
        location: masters_location,
        placement_group_id: placement_group_id,
        firewall_id: firewall['id'],
        network_id: network['id'],
        ssh_key_id: k3s_ssh_key['id'],
        default_ssh_key_ids: default_ssh_key_ids,
        image: image,
        additional_packages: additional_packages,
        additional_post_create_commands: additional_post_create_commands,
        labels: masters_config['labels'],
        taints: masters_config['taints'],
        **add,
      }
    end

    definitions
  end

  def master_definitions_for_delete
    definitions = []

    masters_count.times do |i|
      definitions << {
        instance_type: master_instance_type,
        instance_id: "master#{i + 1}",
      }
    end

    definitions
  end

  def worker_node_pool_definitions(worker_node_pool)
    worker_node_pool_name = worker_node_pool['name']
    worker_instance_type = worker_node_pool['instance_type']
    worker_count = worker_node_pool['instance_count']
    worker_location = worker_node_pool['location'] || masters_location
    labels = worker_node_pool['labels']
    taints = worker_node_pool['taints']

    definitions = []

    worker_count.times do |i|
      definitions << {
        instance_type: worker_instance_type,
        instance_id: "pool-#{worker_node_pool_name}-worker#{i + 1}",
        placement_group_id: placement_group_id(worker_node_pool_name),
        location: worker_location,
        firewall_id: firewall['id'],
        network_id: network['id'],
        ssh_key_id: k3s_ssh_key['id'],
        default_ssh_key_ids: default_ssh_key_ids,
        image: image,
        additional_packages: additional_packages,
        additional_post_create_commands: additional_post_create_commands,
        labels: labels,
        taints: taints,
        **additional_server_settings,
      }
    end

    definitions
  end

  def server_configs
    return @server_configs if @server_configs

    @server_configs = master_definitions_for_create

    worker_node_pools.each do |worker_node_pool|
      @server_configs += worker_node_pool_definitions(worker_node_pool)
    end

    @server_configs
  end

  def hetzner_client
    configuration.hetzner_client
  end

  def kubernetes_client
    @kubernetes_client ||= Kubernetes::Client.new(configuration: configuration)
  end

  def workers_definitions_for_marking
    worker_node_pools.map do |worker_node_pool|
      worker_node_pool_definitions(worker_node_pool)
    end.flatten
  end

  def create_resources
    create_load_balancer if masters_count > 1
    create_servers
  end

  def delete_placement_groups
    Hetzner::PlacementGroup.new(hetzner_client: hetzner_client, cluster_name: cluster_name).delete

    worker_node_pools.each do |pool|
      pool_name = pool['name']
      Hetzner::PlacementGroup.new(hetzner_client: hetzner_client, cluster_name: cluster_name, pool_name: pool_name).delete
    end
  end

  def delete_resources
    Hetzner::LoadBalancer.new(hetzner_client: hetzner_client, cluster_name: cluster_name).delete(high_availability: (masters.size > 1))

    Hetzner::Firewall.new(hetzner_client: hetzner_client, cluster_name: cluster_name).delete(all_servers)

    Hetzner::Network.new(hetzner_client: hetzner_client, cluster_name: cluster_name, existing_network: existing_network).delete

    Hetzner::SSHKey.new(hetzner_client: hetzner_client, cluster_name: cluster_name).delete(public_ssh_key_path: public_ssh_key_path)

    delete_placement_groups
    delete_servers
  end

  def create_servers
    servers = []

    first_master_config = server_configs[0].reject! { |k, _v| %i[labels taints].include?(k) }
    first_master = Hetzner::Server.new(hetzner_client: hetzner_client, cluster_name: cluster_name).create(**first_master_config)
    wait_for_ssh first_master

    threads = server_configs[1..].map do |server_config|
      config = server_config.reject! { |k, _v| %i[labels taints].include?(k) }

      Thread.new do
        server = Hetzner::Server.new(hetzner_client: hetzner_client, cluster_name: cluster_name).create(**config)
        server['_jumphost'] = "#{first_master.dig('public_net', 'ipv4', 'ip')}" if masters_count > 1
        servers << server
      end
    end

    threads.each(&:join) unless threads.empty?

    sleep 1 while servers.size != server_configs.size - 1

    if servers.any? { |server| server.nil? }
      raise StandardError, 'Encountered error during server creation. (Found Nil in server array)'
    end

    wait_for_servers(servers)
  end

  def wait_for_servers(servers)
    threads = servers.map do |server|
      Thread.new { wait_for_ssh server }
    end

    threads.each(&:join) unless threads.empty?
  end

  def delete_servers
    threads = all_servers.map do |server|
      Thread.new do
        Hetzner::Server.new(hetzner_client: hetzner_client, cluster_name: cluster_name).delete(server_name: server['name'])
      end
    end

    threads.each(&:join) unless threads.empty?
  end

  def create_load_balancer
    @load_balancer ||= Hetzner::LoadBalancer.new(hetzner_client: hetzner_client, cluster_name: cluster_name).create(location: masters_location, network_id: network['id'])
  end

  def existing_network
    configuration['existing_network']
  end
end
