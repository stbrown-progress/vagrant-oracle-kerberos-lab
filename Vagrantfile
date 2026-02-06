require_relative "lib/hosts_trigger"

# Root-level multi-machine Vagrantfile.
# Usage:  vagrant up              (brings up all VMs in dependency order)
#         vagrant up kdc          (just the domain controller)
#         vagrant up oracle       (just the Oracle DB)
#         vagrant destroy -f      (tear down everything)
#
# VMs are defined in order so that `vagrant up` provisions the KDC first,
# then Oracle, then the test clients.

Vagrant.configure("2") do |config|

  # ---------------------------------------------------------------------------
  # 1. KDC — Samba AD Domain Controller
  # ---------------------------------------------------------------------------
  config.vm.define "kdc", primary: true do |kdc|
    kdc.vm.box = "generic/ubuntu2204"
    kdc.vm.hostname = "samba-ad-dc"
    kdc.vm.network "public_network"

    kdc.vm.provider "hyperv" do |hv|
      hv.vmname = "samba-ad-dc"
      hv.memory = 1024
      hv.maxmemory = 1024
      hv.enable_virtualization_extensions = true
    end

    kdc.vm.provision "shell", path: "kdc/provision.sh", run: "always"

    kdc.trigger.after :up do |trigger|
      trigger.ruby do |_env, machine|
        ip = machine.ssh_info[:host]
        File.write('.kdc_ip', ip)
        puts "KDC IP [#{ip}] saved to .kdc_ip"
      end
    end

    HostsTrigger.register(kdc, "samba-ad-dc.corp.internal samba-ad-dc", /\bsamba-ad-dc\.corp\.internal\b/)
  end

  # ---------------------------------------------------------------------------
  # 2. Oracle — Database Server (Docker)
  # ---------------------------------------------------------------------------
  config.vm.define "oracle" do |ora|
    ora.vm.box = "generic/ubuntu2204"
    ora.vm.hostname = "oracle"
    ora.vm.network "public_network"

    ora.vm.provider "hyperv" do |hv|
      hv.vmname = "oracle-db"
      hv.memory = 4096
      hv.maxmemory = 4096
      hv.cpus = 2
      hv.enable_virtualization_extensions = true
    end

    kdc_ip = File.exist?('.kdc_ip') ? File.read('.kdc_ip').strip : "127.0.0.1"

    ora.vm.provision "file", source: "lib/fetch_with_retry.sh", destination: "/tmp/fetch_with_retry.sh", run: "always"
    ora.vm.provision "shell", path: "oracle/provision.sh", args: [kdc_ip], run: "always"

    HostsTrigger.register(ora, "oracle.corp.internal oracle", /\boracle\.corp\.internal\b/)
  end

  # ---------------------------------------------------------------------------
  # 3. Test — Linux Client
  # ---------------------------------------------------------------------------
  config.vm.define "test" do |tst|
    tst.vm.box = "generic/ubuntu2204"
    tst.vm.network "public_network"

    tst.vm.provider "hyperv" do |hv|
      hv.vmname = "test-client"
      hv.memory = 1024
      hv.maxmemory = 1024
      hv.enable_virtualization_extensions = true
    end

    kdc_ip = File.exist?('.kdc_ip') ? File.read('.kdc_ip').strip : "127.0.0.1"

    tst.vm.provision "file", source: "lib/fetch_with_retry.sh", destination: "/tmp/fetch_with_retry.sh", run: "always"
    tst.vm.provision "shell", path: "test/provision.sh", args: [kdc_ip], run: "always"

    HostsTrigger.register(tst, "test-client.corp.internal test-client", /\btest-client\.corp\.internal\b/)
  end

  # ---------------------------------------------------------------------------
  # 4. Win-Test — Windows 10 Client
  # ---------------------------------------------------------------------------
  config.vm.define "win-test" do |win|
    win.vm.box = "gusztavvargadr/windows-10"
    win.vm.hostname = "win-client"
    win.vm.network "public_network"
    win.vm.communicator = "winrm"

    win.vm.provider "hyperv" do |hv|
      hv.vmname = "win-client"
      hv.memory = 4096
      hv.maxmemory = 4096
      hv.cpus = 2
      hv.enable_virtualization_extensions = true
      hv.linked_clone = true
    end

    kdc_ip = File.exist?('.kdc_ip') ? File.read('.kdc_ip').strip : "127.0.0.1"

    win.vm.provision "shell", path: "win-test/provision.ps1", args: [kdc_ip], run: "always"

    HostsTrigger.register(win, "win-client.corp.internal win-client", /\bwin-client\.corp\.internal\b/)
  end

end
