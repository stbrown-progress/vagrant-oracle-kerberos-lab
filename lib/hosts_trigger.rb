require "base64"

# Shared helper for updating/cleaning the Windows hosts file from Vagrant triggers.
# Usage in a Vagrantfile:
#
#   require_relative "../lib/hosts_trigger"
#   HostsTrigger.register(config, "oracle.corp.internal oracle", /\boracle\.corp\.internal\b/)
#
module HostsTrigger
  # Register after-up (upsert) and after-destroy (remove) triggers for the
  # Windows hosts file on the Vagrant host machine.
  #
  # @param config   [Vagrant::Config] the top-level Vagrant config object
  # @param hostnames [String]         space-separated hostnames to add (e.g. "oracle.corp.internal oracle")
  # @param pattern   [Regexp]         pattern that matches lines to replace/remove
  def self.register(config, hostnames, pattern)
    # --- After UP: upsert the entry ---
    config.trigger.after :up do |trigger|
      trigger.ruby do |_env, machine|
        ip = machine.ssh_info[:host]
        upsert_hosts_entry(ip, hostnames, pattern)
      end
    end

    # --- After DESTROY: remove the entry ---
    config.trigger.before :destroy do |trigger|
      trigger.ruby do |_env, _machine|
        remove_hosts_entry(pattern)
      end
    end
  end

  private

  def self.upsert_hosts_entry(ip, hostnames, pattern)
    ps = <<~POWERSHELL
      $path = "$env:SystemRoot\\System32\\drivers\\etc\\hosts"
      $entry = "#{ip} #{hostnames}"
      $content = @()
      if (Test-Path $path) {
        $item = Get-Item $path
        if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) {
          $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly
        }
        Copy-Item -Path $path -Destination "$path.bak" -Force
        $content = Get-Content $path
      }
      $content = $content | Where-Object { $_ -notmatch '#{pattern.source}' }
      $content += $entry
      Set-Content -Path $path -Value $content -Encoding ASCII -Force
    POWERSHELL
    run_powershell(ps)
  end

  def self.remove_hosts_entry(pattern)
    ps = <<~POWERSHELL
      $path = "$env:SystemRoot\\System32\\drivers\\etc\\hosts"
      if (Test-Path $path) {
        $item = Get-Item $path
        if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) {
          $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly
        }
        $content = Get-Content $path | Where-Object { $_ -notmatch '#{pattern.source}' }
        Set-Content -Path $path -Value $content -Encoding ASCII -Force
      }
    POWERSHELL
    run_powershell(ps)
  end

  def self.run_powershell(script)
    encoded = Base64.strict_encode64(script.encode("UTF-16LE"))
    system("powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand #{encoded}")
  end
end
