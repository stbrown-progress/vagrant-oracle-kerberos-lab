require "base64"

# Shared helper for updating/cleaning the Windows hosts file from Vagrant triggers.
# Uses a fenced section block so we only ever touch our own lines.
#
# Usage in a Vagrantfile:
#
#   require_relative "../lib/hosts_trigger"
#   HostsTrigger.register(config, "oracle.corp.internal oracle")
#
module HostsTrigger
  SECTION_BEGIN = "# >>> vagrant-lab managed block — do not edit"
  SECTION_END   = "# <<< vagrant-lab managed block"

  def self.register(config, hostnames)
    config.trigger.after :up do |trigger|
      trigger.ruby do |_env, machine|
        ip = machine.ssh_info[:host]
        upsert_hosts_entry(ip, hostnames)
      end
    end

    config.trigger.before :destroy do |trigger|
      trigger.ruby do |_env, _machine|
        remove_hosts_entry(hostnames)
      end
    end
  end

  private

  def self.upsert_hosts_entry(ip, hostnames)
    # Build the entry line we want inside the managed block
    entry = "#{ip} #{hostnames}"

    ps = <<~POWERSHELL
      $path = "$env:SystemRoot\\System32\\drivers\\etc\\hosts"
      $begin = '#{SECTION_BEGIN}'
      $end   = '#{SECTION_END}'
      $entry = '#{entry}'

      if (-not (Test-Path $path)) { return }

      $item = Get-Item $path
      if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) {
        $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly
      }

      # Read the raw text so we never lose existing content
      $raw = [IO.File]::ReadAllText($path)
      $lines = $raw -split "`r?`n"

      # Find our managed block (if it exists)
      $blockStart = -1
      $blockEnd   = -1
      for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimEnd() -eq $begin) { $blockStart = $i }
        if ($lines[$i].TrimEnd() -eq $end)   { $blockEnd   = $i }
      }

      if ($blockStart -ge 0 -and $blockEnd -ge $blockStart) {
        # Extract existing managed entries (between the markers)
        $before  = $lines[0..($blockStart - 1)]
        $managed = @($lines[($blockStart + 1)..($blockEnd - 1)])
        $after   = if ($blockEnd + 1 -lt $lines.Count) { $lines[($blockEnd + 1)..($lines.Count - 1)] } else { @() }

        # Remove any old entry for this hostname set, then add the new one
        $managed = @($managed | Where-Object { $_.Trim() -ne '' -and ($_ -split '\\s+',2)[1] -ne '#{hostnames}' })
        $managed += $entry

        $lines = @($before) + @($begin) + @($managed) + @($end) + @($after)
      }
      else {
        # No managed block yet — append one at the end
        # Strip trailing empty lines before appending
        while ($lines.Count -gt 0 -and $lines[-1].Trim() -eq '') { $lines = $lines[0..($lines.Count - 2)] }
        $lines += ''
        $lines += $begin
        $lines += $entry
        $lines += $end
      }

      [IO.File]::WriteAllText($path, ($lines -join "`r`n") + "`r`n")
    POWERSHELL
    run_powershell(ps)
  end

  def self.remove_hosts_entry(hostnames)
    ps = <<~POWERSHELL
      $path = "$env:SystemRoot\\System32\\drivers\\etc\\hosts"
      $begin = '#{SECTION_BEGIN}'
      $end   = '#{SECTION_END}'

      if (-not (Test-Path $path)) { return }

      $item = Get-Item $path
      if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) {
        $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly
      }

      $raw = [IO.File]::ReadAllText($path)
      $lines = $raw -split "`r?`n"

      $blockStart = -1
      $blockEnd   = -1
      for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimEnd() -eq $begin) { $blockStart = $i }
        if ($lines[$i].TrimEnd() -eq $end)   { $blockEnd   = $i }
      }

      if ($blockStart -ge 0 -and $blockEnd -ge $blockStart) {
        $before  = $lines[0..($blockStart - 1)]
        $managed = @($lines[($blockStart + 1)..($blockEnd - 1)])
        $after   = if ($blockEnd + 1 -lt $lines.Count) { $lines[($blockEnd + 1)..($lines.Count - 1)] } else { @() }

        # Remove the entry for this hostname set
        $managed = @($managed | Where-Object { $_.Trim() -ne '' -and ($_ -split '\\s+',2)[1] -ne '#{hostnames}' })

        if ($managed.Count -eq 0) {
          # Block is empty — remove the markers too
          $lines = @($before) + @($after)
        }
        else {
          $lines = @($before) + @($begin) + @($managed) + @($end) + @($after)
        }

        [IO.File]::WriteAllText($path, ($lines -join "`r`n") + "`r`n")
      }
    POWERSHELL
    run_powershell(ps)
  end

  def self.run_powershell(script)
    encoded = Base64.strict_encode64(script.encode("UTF-16LE"))
    system("powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand #{encoded}")
  end
end
