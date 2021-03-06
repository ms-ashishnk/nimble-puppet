require 'fileutils'
require "net/https"
require "uri"
require "nimblerest"
require "facter"

Puppet::Type.type(:nimble_volume).provide(:nimble_volume) do
  desc "Work on Nimble Array Volumes"
  mk_resource_methods

  def create
    $token=Facter.value('token')
    perfPolicyId = nil
    requestedParams = Hash(resource)
    requestedParams.delete(:provider)
    requestedParams.delete(:ensure)
    requestedParams.delete(:transport)
    requestedParams.delete(:loglevel)
    requestedParams.delete(:perfpolicy)
    requestedParams.delete(:config)
    requestedParams.delete(:mp)
    if requestedParams[:vol_coll]
      $vol_coll = requestedParams[:vol_coll]
      requestedParams.delete(:vol_coll)
    else
      if $dirtyHash.size > 0
        requestedParams[:volcoll_id] = ''
      end
    end

    if $dirtyHash.size == 0
      if requestedParams[:clone] && requestedParams[:clone] == true
        requestedParams[:base_snap_id] = returnSnapId(resource[:transport], requestedParams[:base_snap_name])
        if requestedParams[:base_snap_id] == nil
          puts 'Base Snapshot not found'
          return false
        end
      end
      requestedParams.delete(:base_snap_name)
    else
      if $dirtyHash.key?('clone')
        puts 'Base snapshot cannot be updated with an existing volume'
        return false
      end
    end

    if requestedParams[:restore_from] && requestedParams[:restore_from] != nil
      requestedParams[:base_snap_id] = returnSnapId(resource[:transport], requestedParams[:restore_from])
      if requestedParams[:base_snap_id] == nil
        puts 'Base snap id not found to restore volume'
        return false
      end
      requestedParams.delete(:restore_from)
      volId = returnVolId(resource[:name], resource[:transport])
      if volId == nil
        puts 'Voulme is non existent to restore from snapshot'
        return false
      end
      begin
        self.putVolumeOffline(resource)
        doPUT(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+volId, {"data" => {"online" => "false", "force" => "true"}}, {"X-Auth-Token" => $token})
        doPOST(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/#{volId}/actions/restore", {"data" => {"base_snap_id" => requestedParams[:base_snap_id], "id" => volId }}, {"X-Auth-Token" => $token})
        doPUT(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+volId, {"data" => {"online" => "true"}}, {"X-Auth-Token" => $token})
      rescue => e
        #puts e.message
      end
      return true
    end

    unless resource[:perfpolicy].nil?
      perfPolicyId = returnPerfPolicyId(resource[:transport], resource[:perfpolicy])
      if perfPolicyId.nil?
        raise resource[:perfpolicy] + " does not exist"
      end
      requestedParams["perfpolicy_id"] = perfPolicyId
    end

    if $dirtyHash.size == 0
      requestedParams.delete(:force)
      puts "Creating New Volume #{resource[:name]}"
      vol = doPOST(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes", {"data" => requestedParams}, {"X-Auth-Token" => $token})
      begin
        vol_col_id = vc_id(resource[:transport], $vol_coll)
        if vol_col_id != nil
          doPUT(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+vol['data']['id'], {"data" => {:volcoll_id => vol_col_id }}, {"X-Auth-Token" => $token})
        end
      rescue => e
        #puts e.message
      end
    else
      volId = returnVolId(resource[:name], resource[:transport])
      puts "Updating existing Volume #{resource[:name]} with id = #{volId}. Values to change #{$dirtyHash}"
      if resource[:force].to_s == "true"
        $dirtyHash[:force] = true
      end
      if $dirtyHash['size']
        Facter.add(resource[:name]) do
          setcode do
            'refresh'
          end
        end
      end
      if $dirtyHash['online'].to_s == 'false'
        self.putVolumeOffline(resource)
      end
      if $vol_coll
        $dirtyHash[:volcoll_id] = vc_id(resource[:transport], $vol_coll)
        if $dirtyHash[:volcoll_id] != nil
          doPUT(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+volId, {"data" => {:volcoll_id => ''}}, {"X-Auth-Token" => $token})
        end
      end
      $json = doPUT(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+volId, {"data" => $dirtyHash}, {"X-Auth-Token" => $token})
    end

  end

  def destroy
    $token=Facter.value('token')
    volId = returnVolId(resource[:name], resource[:transport])
    if !volId.nil?
      volDetails = returnVolDetails(resource[:transport], resource[:name])
    else
      puts 'Volume '+ resource[:name] + ' not found'
      return nil
    end

    self.putVolumeOffline(resource)


    begin
    if volId.nil?
      puts 'Volume '+ resource[:name] + ' not found'
      return nil
    else
      puts 'Removing ' + resource[:name]
      if resource[:force]
        # Put the volume offline
        puts "Specified force=>true. Putting volume offline"
        doPUT(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+volId, {"data" => {"online" => "false", "force" => "true"}}, {"X-Auth-Token" => $token})
        # Delete all Snapshots
        puts "Specified force=>true. Deleting all snapshots"
        allSnaps = returnAllSnapshots(resource[:name], resource[:transport])
        allSnaps.each do |snap|
          puts "\tDeleting " + snap["name"]
          doDELETE(resource[:transport]['server'], resource[:transport]['port'], "/v1/snapshots/"+snap["id"], {"X-Auth-Token" => $token})
        end
        doPUT(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+volId, {"data" => {"volcoll_id" => ""}}, {"X-Auth-Token" => $token})
        doDELETE(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+volId, {"X-Auth-Token" => $token})
      else
        doPUT(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+volId, {"data" => {"volcoll_id" => ""}}, {"X-Auth-Token" => $token})
        doPUT(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+volId, {"data" => {"online" => "false"}}, {"X-Auth-Token" => $token})
        doDELETE(resource[:transport]['server'], resource[:transport]['port'], "/v1/volumes/"+volId, {"X-Auth-Token" => $token})
      end
    end
    rescue => e
    end

  end

  def exists?
    deleteRequested = false
    if resource[:ensure].to_s == "absent"
      deleteRequested = true
    end
    requestedParams = Hash(resource)

    if requestedParams[:vol_coll]
      requestedParams[:volcoll_id] = vc_id(resource[:transport], requestedParams[:vol_coll])
      requestedParams.delete(:vol_coll)
    else
      requestedParams[:volcoll_id] = ''
    end

    if requestedParams[:clone] && requestedParams[:clone] == true
      requestedParams[:base_snap_id] = returnSnapId(resource[:transport], requestedParams[:base_snap_name])
      if requestedParams[:base_snap_id] == nil
        requestedParams.delete(:base_snap_id)
      end
      requestedParams.delete(:base_snap_name)
    end

    if requestedParams[:restore_from] && requestedParams[:restore_from] != nil
      requestedParams[:base_snap_id] = returnSnapId(resource[:transport], requestedParams[:restore_from])
      if requestedParams[:base_snap_id] == nil
        requestedParams.delete(:base_snap_id)
      end
      requestedParams.delete(:restore_from)
      volId = returnVolId(resource[:name], resource[:transport])
      if volId != nil
        return false
      end
    end

    $dirtyHash=Hash.new
    $token=Facter.value('token')
    allVolumes = returnAllVolumes(resource[:transport])
    allVolumes.each do |volume|
      if resource[:name].eql? volume["name"]
        if deleteRequested
          return true
        end
        requestedParams.each do |k, v|
          key = k.to_s
          if volume.key?(key)
            if volume[key].to_s != v.to_s
              $dirtyHash[key] = v
            end
          end
        end
        if $dirtyHash.size != 0
          return false
        else
          return true
        end
      end
    end
    return false
  end

  def pre_flight(mp, serial_num)
    if mp.to_s == "true"
      return Puppet::Util::Execution.execute('find /dev -name "[uuid]*' + serial_num + '*" | tr "\n" " " ')
    else
      return Puppet::Util::Execution.execute('find /dev -name "[scsi]*' + serial_num + '*" | tr "\n" " " ')
    end
  end

  def fetch_data(mp, serial_num)
    if mp.to_s == "true"
      self.retrieve_data_w_multipath(serial_num)
    else
      self.retrieve_data_wo_multipath(serial_num)
    end
  end

  def iscsireDiscover
    if system("/usr/sbin/iscsiadm -m node -p #{$device[:target]}:#{$device[:port]} >> /dev/null 2>&1")
      if system("/usr/sbin/iscsiadm -m discovery -t st -p #{$device[:target]}:#{$device[:port]} >> /dev/null 2>&1")
        if $device[:mp].to_s == "true"
          Puppet::Util::Execution.execute("/usr/sbin/multipath -r")
        end
      else
        return nil
      end
    end
  end

  def isIscsiLoggedIn
    return system("/usr/sbin/iscsiadm -m session | grep -m 1 #{$device[:target_name]}")
  end

  def trim(pl)
    return pl.chomp
  end

  def retrieve_data_wo_multipath(serial_num)
    begin
      $device[:originalPath] = trim(Puppet::Util::Execution.execute('find /dev -name "[scsi]*' + serial_num + '*" | tr \'\n\' \' \' | cut -d \' \' -f1'))
      if $device[:originalPath] != nil
        $device[:map] = trim(Puppet::Util::Execution.execute("ls -l "+ $device[:originalPath] +" | awk '{print$11}' | cut -d '/' -f3  "))
        $device[:path] = trim(Puppet::Util::Execution.execute('lsblk -fp | grep -m 1 '+$device[:map]+' | awk \'{print$1}\' '))
        $device[:fs] = trim(Puppet::Util::Execution.execute('lsblk -fp | grep -m 1 '+$device[:map]+' | awk \'{print$2}\'   '))
        $device[:label] = trim(Puppet::Util::Execution.execute('lsblk -fp | grep -m 1 '+$device[:map]+' | awk \'{print$3}\'  '))
        $device[:uuid] = trim(Puppet::Util::Execution.execute('lsblk -fp | grep -m 1 '+$device[:map]+' | awk \'{print$4}\' '))
        $device[:mount_point] = trim(Puppet::Util::Execution.execute('lsblk -fp | grep -m 1 '+$device[:map]+' | awk \'{print$5}\' '))
      end
    rescue => e
    end
  end

  def retrieve_data_w_multipath(serial_num)
    begin
      $device[:originalPath] = trim(Puppet::Util::Execution.execute('find /dev -name "[uuid]*' + serial_num + '*" | tr \'\n\' \' \' | cut -d \' \' -f1 '))
      if $device[:originalPath] != nil
        $device[:map] = trim(Puppet::Util::Execution.execute("multipath -ll | grep -m 1 #{serial_num} | cut -d ' ' -f1 "))
        $device[:path] = trim(Puppet::Util::Execution.execute('lsblk -fpl | grep -m 1 '+$device[:map]+' | awk \'{print$1}\' '))
        $device[:fs] = trim(Puppet::Util::Execution.execute('lsblk -fpl | grep -m 1 '+$device[:map]+' | awk \'{print$2}\'  '))
        $device[:label] = trim(Puppet::Util::Execution.execute('lsblk -fpl | grep -m 1 '+$device[:map]+' | awk \'{print$3}\' '))
        $device[:uuid] = trim(Puppet::Util::Execution.execute('lsblk -fpl | grep -m 1 '+$device[:map]+' | awk \'{print$4}\' '))
        $device[:mount_point] = trim(Puppet::Util::Execution.execute('lsblk -fpl | grep -m 1 '+$device[:map]+' | awk \'{print$5}\' '))
      end
    rescue => e
    end
  end

  def unmount(path)
    if !self.if_mount(path)
      Puppet::Util::Execution.execute('umount ' + path)
      self.removefstabentry
      self.iscsiLogout
    end
  end

  def if_mount(path)
    return !system('mount | grep ' + path)
  end

  def iscsiLogout
    if !self.isIscsiLoggedIn
      return true
    end
    if system("/usr/sbin/iscsiadm -m node -p #{$device[:target]}:#{$device[:port]} >> /dev/null 2>&1")
      if Puppet::Util::Execution.execute("/usr/sbin/iscsiadm -m node -u -T #{$device[:target_name]} -p #{$device[:target]}:#{$device[:port]} >> /dev/null 2>&1")
        Puppet::Util::Execution.execute("/usr/sbin/iscsiadm -m discovery -t st -p #{$device[:target]}:#{$device[:port]} >> /dev/null 2>&1")
        if $device[:mp].to_s == "true"
          Puppet::Util::Execution.execute("/usr/sbin/multipath -r")
        end
        return true
      else
        return false
      end
    end
  end

  def removefstabentry
    Puppet::Util::Execution.execute("/usr/bin/sed -i /#{$device[:uuid]}/d /etc/fstab")
  end

  def putVolumeOffline(resource)
    volId = returnVolId(resource[:name], resource[:transport])
    if !volId.nil?
      volDetails = returnVolDetails(resource[:transport], resource[:name])
    else
      puts 'Volume '+ resource[:name] + ' not found'
      return nil
    end

    $device = Hash.new
    $device[:serial_num] = volDetails['data'][0]['serial_number']
    $device[:target_name] = volDetails['data'][0]['target_name']
    $device[:target] = resource[:config]['target']
    $device[:port] = resource[:config]['port']
    $device[:mp] = resource[:mp]

    if self.isIscsiLoggedIn
      if self.pre_flight($device[:mp], $device[:serial_num]) != nil
        self.fetch_data($device[:mp], $device[:serial_num])
        if !self.if_mount($device[:path])
          self.unmount($device[:path])
        else
          self.iscsiLogout
        end
        self.iscsireDiscover
      end
    end
  end


end
