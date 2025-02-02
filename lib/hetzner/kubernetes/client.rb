# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'open-uri'
require 'tempfile'
require_relative '../utils'

module Kubernetes
  class Client
    include Utils

    def initialize(configuration:)
      @configuration = configuration
    end

    def deploy(masters:, workers:, master_definitions:, worker_definitions:, default_ssh_keys:)
      @masters = masters
      @workers = workers
      @master_definitions = master_definitions
      @worker_definitions = worker_definitions

      @kube_api_server_args = configuration.fetch('kube_api_server_args', [])
      @kube_scheduler_args = configuration.fetch('kube_scheduler_args', [])
      @kube_controller_manager_args = configuration.fetch('kube_controller_manager_args', [])
      @kube_cloud_controller_manager_args = configuration.fetch('kube_cloud_controller_manager_args', [])
      @kubelet_args = configuration.fetch('kubelet_args', [])
      @kube_proxy_args = configuration.fetch('kube_proxy_args', [])
      @private_ssh_key_path = File.expand_path(configuration['private_ssh_key_path'])
      @public_ssh_key_path = File.expand_path(configuration['public_ssh_key_path'])
      @default_ssh_keys = default_ssh_keys
      @cluster_name = configuration['cluster_name']

      prepare_ssh_connections

      set_up_k3s

      update_nodes

      post_setup_deployments
    end

    def upgrade
      worker_upgrade_concurrency = workers.size - 1
      worker_upgrade_concurrency = 1 if worker_upgrade_concurrency.zero?

      cmd = <<~BASH
        kubectl apply -f - <<-EOF
          apiVersion: upgrade.cattle.io/v1
          kind: Plan
          metadata:
            name: k3s-server
            namespace: system-upgrade
            labels:
              k3s-upgrade: server
          spec:
            concurrency: 1
            version: #{new_k3s_version}
            nodeSelector:
              matchExpressions:
                - {key: node-role.kubernetes.io/master, operator: In, values: ["true"]}
            serviceAccountName: system-upgrade
            tolerations:
            - key: "CriticalAddonsOnly"
              operator: "Equal"
              value: "true"
              effect: "NoExecute"
            cordon: true
            upgrade:
              image: rancher/k3s-upgrade
        EOF
      BASH

      run cmd, kubeconfig_path: kubeconfig_path

      cmd = <<~BASH
        kubectl apply -f - <<-EOF
          apiVersion: upgrade.cattle.io/v1
          kind: Plan
          metadata:
            name: k3s-agent
            namespace: system-upgrade
            labels:
              k3s-upgrade: agent
          spec:
            concurrency: #{worker_upgrade_concurrency}
            version: #{new_k3s_version}
            nodeSelector:
              matchExpressions:
                - {key: node-role.kubernetes.io/master, operator: NotIn, values: ["true"]}
            serviceAccountName: system-upgrade
            prepare:
              image: rancher/k3s-upgrade
              args: ["prepare", "k3s-server"]
            cordon: true
            upgrade:
              image: rancher/k3s-upgrade
        EOF
      BASH

      run cmd, kubeconfig_path: kubeconfig_path

      puts 'Upgrade will now start. Run `watch kubectl get nodes` to see the nodes being upgraded. This should take a few minutes for a small cluster.'
      puts 'The API server may be briefly unavailable during the upgrade of the controlplane.'

      updated_configuration = configuration.raw
      updated_configuration['k3s_version'] = new_k3s_version

      File.write(config_file, updated_configuration.to_yaml)
    end

    private

    attr_reader :configuration, :masters, :workers, :kube_api_server_args, :kube_scheduler_args, :default_ssh_keys,
                :kube_controller_manager_args, :kube_cloud_controller_manager_args, :kubelet_args, :kube_proxy_args,
                :private_ssh_key_path, :public_ssh_key_path, :master_definitions, :worker_definitions, :cluster_name

    def prepare_ssh_connections
      if masters.size > 1
        master_1 = @masters.first
        @masters = masters.map do |server|
          server['_jumphost'] = master_1.dig('public_net', 'ipv4', 'ip')
          server
        end

        @workers = workers.map do |server|
          server['_jumphost'] = master_1.dig('public_net', 'ipv4', 'ip')
          server
        end

        @masters[0]['_jumphost'] = nil
      end
    end

    def set_up_k3s
      k3s_install_script_uri = URI.parse('https://get.k3s.io')
      k3s_install_script_response = Net::HTTP.get_response(k3s_install_script_uri)

      k3s_install_script_contents = k3s_install_script_response.body

      k3s_install_script = Tempfile.new('k3s_install_script')
      k3s_install_script.write(k3s_install_script_contents)
      k3s_install_script.rewind

      k3s_latest_release = URI.parse('https://api.github.com/repos/k3s-io/k3s/releases/latest')
      k3s_binary_response = Net::HTTP.get_response(k3s_latest_release)

      k3s_binary_contents = k3s_binary_response.body

      k3s_latest_version = JSON.parse(k3s_binary_contents)['tag_name']

      k3s_binary = Tempfile.new('k3s_binary')
      k3s_binary.write(URI.parse("https://github.com/k3s-io/k3s/releases/download/#{k3s_latest_version}/k3s").read)
      k3s_binary.rewind

      puts master_install_script(first_master)

      set_up_first_master(k3s_binary, k3s_install_script)
      set_up_additional_masters(k3s_binary, k3s_install_script)
      set_up_workers(k3s_binary, k3s_install_script)

      k3s_install_script.close
      k3s_install_script.unlink

      k3s_binary.close
      k3s_binary.unlink
    end

    def set_up_first_master(k3s_binary, install_script)
      puts
      puts "Deploying k3s to first master (#{first_master['name']})..."

      ssh(first_master, master_install_script(first_master), scp_files: { "#{k3s_binary.path}" => '/usr/local/bin/k3s', "#{install_script.path}" => '/root/install_k3s.sh' }, print_output: true)
      ssh first_master, ensure_ssh_keys(default_ssh_keys)

      puts
      puts 'Waiting for the control plane to be ready...'

      sleep 10

      puts
      puts '...k3s has been deployed to first master.'

      save_kubeconfig
    end

    def set_up_additional_masters(k3s_binary, install_script)
      return unless masters.size > 1

      threads = masters[1..].map do |master|
        Thread.new do
          puts
          puts "Deploying k3s to master #{master['name']}..."

          ssh(master, master_install_script(master), scp_files: { "#{k3s_binary.path}" => '/usr/local/bin/k3s', "#{install_script.path}" => '/root/install_k3s.sh' }, print_output: true)
          ssh master, ensure_ssh_keys(default_ssh_keys)

          puts
          puts "...k3s has been deployed to master #{master['name']}."
        end
      end

      threads.each(&:join) unless threads.empty?
    end

    def set_up_workers(k3s_binary, install_script)
      threads = workers.map do |worker|
        Thread.new do
          puts
          puts "Deploying k3s to worker (#{worker['name']})..."

          ssh(worker, worker_install_script(worker), scp_files: { "#{k3s_binary.path}" => '/usr/local/bin/k3s', "#{install_script.path}" => '/root/install_k3s.sh' }, print_output: true)

          ssh worker, ensure_ssh_keys(default_ssh_keys)

          puts
          puts "...k3s has been deployed to worker (#{worker['name']})."
        end
      end

      threads.each(&:join) unless threads.empty?
    end

    def ensure_ssh_keys(keys)
      return '#' unless keys.size > 0
      commands = <<~BASH
        echo "#{keys[0]['public_key']} #{keys[0]['name']}" > .ssh/authorized_keys
      BASH
      return commands unless keys.size > 1
      commands = keys[1..].map do |key|
        <<~BASH
          echo "#{key['public_key']} #{key['name']}" >> .ssh/authorized_keys
        BASH
      end
      return commands.join("\n")
    end

    def post_setup_deployments
      deploy_cloud_controller_manager
      deploy_csi_driver
      deploy_system_upgrade_controller
    end

    def update_nodes
      mark_nodes mark_type: :labels
      mark_nodes mark_type: :taints
    end

    def first_master
      @first_master ||= masters.first
    end

    def kube_api_server_args_list
      return '' if kube_api_server_args.empty?

      kube_api_server_args.map do |arg|
        " --kube-apiserver-arg=\"#{arg}\" "
      end.join
    end

    def kube_scheduler_args_list
      return '' if kube_scheduler_args.empty?

      kube_scheduler_args.map do |arg|
        " --kube-scheduler-arg=\"#{arg}\" "
      end.join
    end

    def kube_controller_manager_args_list
      return '' if kube_controller_manager_args.empty?

      kube_controller_manager_args.map do |arg|
        " --kube-controller-manager-arg=\"#{arg}\" "
      end.join
    end

    def kube_cloud_controller_manager_args_list
      return '' if kube_cloud_controller_manager_args.empty?

      kube_cloud_controller_manager_args.map do |arg|
        " --kube-cloud-controller-manager-arg=\"#{arg}\" "
      end.join
    end

    def kubelet_args_list
      return '' if kubelet_args.empty?

      kubelet_args.map do |arg|
        " --kubelet-arg=\"#{arg}\" "
      end.join
    end

    def kube_proxy_args_list
      return '' if kube_proxy_args.empty?

      kube_api_server_args.map do |arg|
        " --kube-proxy-arg=\"#{arg}\" "
      end.join
    end

    def api_server_ip
      return @api_server_ip if @api_server_ip

      @api_server_ip ||= if masters.size > 1
          load_balancer_name = "#{cluster_name}-api"
          load_balancer = hetzner_client.get('/load_balancers')['load_balancers'].detect do |lb|
            lb['name'] == load_balancer_name
          end
          load_balancer['public_net']['ipv4']['ip']
        else
          first_master_public_ip
        end
    end

    def master_install_script(master)
      server = master == first_master ? ' --cluster-init ' : " --server https://#{masters.any? { |m_srv| m_srv.dig('public_net', 'ipv4').nil? } ? first_master_private_ip : api_server_ip}:6443 "
      flannel_interface = find_flannel_interface(master)
      enable_encryption = configuration.fetch('enable_encryption', false)
      flannel_wireguard = if enable_encryption
          if Gem::Version.new(k3s_version.scan(/\Av(.*)\+.*\Z/).flatten.first) >= Gem::Version.new('1.23.6')
            ' --flannel-backend=wireguard-native '
          else
            ' --flannel-backend=wireguard '
          end
        else
          ' '
        end

      extra_args = "#{kube_api_server_args_list} #{kube_scheduler_args_list} #{kube_controller_manager_args_list} #{kube_cloud_controller_manager_args_list} #{kubelet_args_list} #{kube_proxy_args_list}"
      taint = schedule_workloads_on_masters? ? ' ' : ' --node-taint CriticalAddonsOnly=true:NoExecute '
      external_ip_arg = master.dig('public_net', 'ipv4').nil? ? '' : "--node-external-ip=$(hostname -I | awk '{print $1}')"
      private_ip_awk_column = master.dig('public_net', 'ipv4').nil? ? '$1' : '$2'

      <<~SCRIPT
        chmod +x /usr/local/bin/k3s;
        chmod +x /root/install_k3s.sh;
        INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_VERSION='#{k3s_version}' K3S_TOKEN='#{k3s_token}' INSTALL_K3S_EXEC="server \
          --disable-cloud-controller \
          --disable servicelb \
          --disable traefik \
          --disable local-storage \
          --disable metrics-server \
          --write-kubeconfig-mode=644 \
          --node-name="$(hostname -f)" \
          --cluster-cidr=10.244.0.0/16 \
          --etcd-expose-metrics=true \
          #{flannel_wireguard} \
          --kube-controller-manager-arg="bind-address=0.0.0.0" \
          --kube-proxy-arg="metrics-bind-address=0.0.0.0" \
          --kube-scheduler-arg="bind-address=0.0.0.0" \
          #{taint} #{extra_args} \
          --kubelet-arg="cloud-provider=external" \
          --advertise-address=$(hostname -I | awk '{print #{private_ip_awk_column}}') \
          --node-ip=$(hostname -I | awk '{print #{private_ip_awk_column}}') \
          #{external_ip_arg} \
          --flannel-iface=#{flannel_interface} \
          #{server} #{tls_sans}" sh /root/install_k3s.sh;
        systemctl start k3s.service
      SCRIPT
    end

    def worker_install_script(worker)
      flannel_interface = find_flannel_interface(worker)
      external_ip_arg = worker.dig('public_net', 'ipv4').nil? ? '' : "--node-external-ip=$(hostname -I | awk '{print $1}')"
      private_ip_awk_column = worker.dig('public_net', 'ipv4').nil? ? '$1' : '$2'

      <<~BASH
        chmod +x /usr/local/bin/k3s;
        chmod +x /root/install_k3s.sh;
        INSTALL_K3S_SKIP_DOWNLOAD=true K3S_TOKEN='#{k3s_token}' INSTALL_K3S_VERSION='#{k3s_version}' K3S_URL='https://#{first_master_private_ip}:6443' INSTALL_K3S_EXEC="agent \
          --node-name="$(hostname -f)" \
          --kubelet-arg="cloud-provider=external" \
          --node-ip=$(hostname -I | awk '{print #{private_ip_awk_column}}') \
          #{external_ip_arg} \
          --flannel-iface=#{flannel_interface}" sh /root/install_k3s.sh;
        systemctl start k3s-agent.service
      BASH
    end

    def find_flannel_interface(server)
      if ssh(server, 'lscpu | grep Vendor') =~ /Intel/
        'ens10'
      else
        'enp7s0'
      end
    end

    def hetzner_client
      configuration.hetzner_client
    end

    def first_master_public_ip
      @first_master_public_ip ||= first_master.dig('public_net', 'ipv4', 'ip')
    end

    def first_master_private_ip
      @first_master_private_ip ||= first_master.dig('private_net', 0, 'ip')
    end

    def save_kubeconfig
      kubeconfig = ssh(first_master, 'cat /etc/rancher/k3s/k3s.yaml')
        .gsub('127.0.0.1', api_server_ip)
        .gsub('default', configuration['cluster_name'])

      File.write(kubeconfig_path, kubeconfig)

      FileUtils.chmod 'go-r', kubeconfig_path
    end

    def kubeconfig_path
      @kubeconfig_path ||= File.expand_path(configuration['kubeconfig_path'])
    end

    def schedule_workloads_on_masters?
      schedule_workloads_on_masters = configuration['schedule_workloads_on_masters']
      schedule_workloads_on_masters ? !!schedule_workloads_on_masters : false
    end

    def k3s_version
      @k3s_version ||= configuration['k3s_version']
    end

    def k3s_token
      @k3s_token ||= begin
          token = ssh(first_master, '{ TOKEN=$(< /var/lib/rancher/k3s/server/node-token); } 2> /dev/null; echo $TOKEN')

          if token.empty?
            SecureRandom.hex
          else
            token.split(':').last
          end
        end
    end

    def tls_sans
      sans = " --tls-san=#{api_server_ip} "

      masters.each do |master|
        master_private_ip = master['private_net'][0]['ip']
        sans += " --tls-san=#{master_private_ip} "
      end

      sans
    end

    def mark_nodes(mark_type:)
      check_kubectl

      action = mark_type == :labels ? 'label' : 'taint'

      if master_definitions.first[mark_type]
        master_labels = master_definitions.first[mark_type].map { |k, v| "#{k}=#{v}" }.join(' ')
        master_node_names = []

        master_definitions.each do |master|
          master_node_names << "#{configuration['cluster_name']}-#{master[:instance_type]}-#{master[:instance_id]}"
        end

        master_node_names = master_node_names.join(' ')

        cmd = "kubectl #{action} --overwrite nodes #{master_node_names} #{master_labels}"

        run cmd, kubeconfig_path: kubeconfig_path
      end

      return unless worker_definitions.any?

      worker_definitions.each do |worker|
        next unless worker[mark_type]

        worker_labels = worker[mark_type].map { |k, v| "#{k}=#{v}" }.join(' ')
        worker_node_name = "#{configuration['cluster_name']}-#{worker[:instance_type]}-#{worker[:instance_id]}"

        cmd = "kubectl #{action} --overwrite nodes #{worker_node_name} #{worker_labels}"

        run cmd, kubeconfig_path: kubeconfig_path
      end
    end

    def deploy_cloud_controller_manager
      check_kubectl

      puts
      puts 'Deploying Hetzner Cloud Controller Manager...'

      cmd = <<~BASH
        kubectl apply -f - <<-EOF
          apiVersion: "v1"
          kind: "Secret"
          metadata:
            namespace: 'kube-system'
            name: 'hcloud'
          stringData:
            network: "#{configuration['existing_network'] || cluster_name}"
            token: "#{configuration.hetzner_token}"
        EOF
      BASH

      run cmd, kubeconfig_path: kubeconfig_path

      cmd = 'kubectl apply -f https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/latest/download/ccm-networks.yaml'

      run cmd, kubeconfig_path: kubeconfig_path

      puts '...Cloud Controller Manager deployed'
    end

    def deploy_system_upgrade_controller
      check_kubectl

      puts
      puts 'Deploying k3s System Upgrade Controller...'

      cmd = 'kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/v0.9.1/system-upgrade-controller.yaml'

      run cmd, kubeconfig_path: kubeconfig_path

      puts '...k3s System Upgrade Controller deployed'
    end

    def deploy_csi_driver
      check_kubectl

      puts
      puts 'Deploying Hetzner CSI Driver...'

      cmd = <<~BASH
        kubectl apply -f - <<-EOF
          apiVersion: "v1"
          kind: "Secret"
          metadata:
            namespace: 'kube-system'
            name: 'hcloud-csi'
          stringData:
            token: "#{configuration.hetzner_token}"
        EOF
      BASH

      run cmd, kubeconfig_path: kubeconfig_path

      cmd = 'kubectl apply -f https://raw.githubusercontent.com/hetznercloud/csi-driver/master/deploy/kubernetes/hcloud-csi.yml'

      run cmd, kubeconfig_path: kubeconfig_path

      puts '...CSI Driver deployed'
    end

    def check_kubectl
      return if which('kubectl')

      puts 'Please ensure kubectl is installed and in your PATH.'
      exit 1
    end

    def first_master_private_ip
      @first_master_private_ip ||= first_master['private_net'][0]['ip']
    end
  end
end
