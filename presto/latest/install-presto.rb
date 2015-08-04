#!/usr/bin/ruby
require 'net/http'
require 'json'
require 'optparse'


def parseOptions
  config_options = {
    :port => 9083,
    :cli => true,
    :version => "0.110"
  }

  opt_parser = OptionParser.new do |opt|
      opt.banner = "Usage: presto-install [OPTIONS]"

       opt.on("-d",'--home-dir [ Home Directory ]',
             "Ex : /home/hadoop/.versions/presto-server-0.95/ )") do |presto_home|
            config_options[:presto_home] = presto_home
      end

      opt.on("-p",'--hive-port [ Hive Metastore Port ]',
             "Ex : 9083 )") do |port|
            config_options[:port] = port
      end

      opt.on("-m",'--MaxMemory [ Memory Specified in Java -Xmx Formatting ]',
             "Ex : 512M )") do |xmx_value|
            config_options[:xmx] = xmx_value
      end

      opt.on("-t",'--task-max-memory [ Memory Specified in Presto task.max.memory ]',
             "Ex : 512MB )") do |task_max_memory|
            config_options[:task_max_memory] = task_max_memory
      end

      opt.on("-v",'--version [ Version of Presto to Install. See README for supported versions ]',
             "Ex : 0.95 )") do |version|
            config_options[:version] = version
      end

      opt.on("-b",'--binary [ Location of Self Compiled Binary of Presto. Assuming directory layout of tarbal downloaded from Prestodb.io ]',
             "Ex : s3://mybuctet/compiled/presto-compiled.tar.gz") do |bin|
            config_options[:binary] = bin
      end

      opt.on("-c",'--install-cli [ Install Presto-CLI. By default set to true ]',
             "Ex : false") do |cli|
            config_options[:cli] = cli
      end

      opt.on("-j","--cli-jar [ Location of custom CLI jar (implies -c option) ]",
             "Ex : s3://mybucket/presto-cli.jar") do |cli_jar|
            config_options[:cli_jar] = cli_jar
            config_options[:cli] = true
      end

      opt.on("-M",'--metastore-uri [ Location of Already Running Hive MetaStore. This will stop the BA from launching the Hive MetaStore Service on the Master Instance ]',
             "Ex : thrift://192.168.0.1:9083") do |metaURI|
            config_options[:metaURI] = metaURI
      end

      opt.on("-H",'--hiveConfig [ Hive Specifc Configuration for Catalog, Keys seperated by comma ]',
             "Ex : hive.s3.max-client-retries=50,hive.s3.connect-timeout=2m") do |hiveConf|
            config_options[:hiveConf] = hiveConf
      end

      opt.on('-h', '--help', 'Display this message') do
        puts opt
        exit
      end

  end
  opt_parser.parse!
  return config_options
end

@parsed = parseOptions
puts "Installing Presto With Java 1.8 Requirement"

@tmp_presto_home = "/home/hadoop/presto_tmp/presto-server-#{@parsed[:version]}"

unless @parsed[:binary]
  @parsed[:binary] = "s3://support.elasticmapreduce/bootstrap-actions/presto/versions/#{@parsed[:version]}/presto-server-#{@parsed[:version]}.tar.gz"
    @user_binary = false
else
    # The assumption here is that a person that is providing a binary has either
    # downloaded the binary from prestodb.io or built from source from the
    # presto github repo (or a fork of that repo).  All of these methods produce
    # a gzipped tarball with a top-level directory with the same name as the
    # basename of the file (e.g., presto-server-0.107,
    # presto-server-0.108-SNAPSHOT, etc.).
  @parsed[:version] = File.basename(@parsed[:binary], ".tar.gz").split("-")[2..-1].join('-')
    @user_binary = true
end

unless @parsed[:presto_home]
  @presto_home = "/var/opt/presto/"
else
  @presto_home = @parsed[:presto_home]
end

puts "Using Binary From: #{@parsed[:binary]} and installing to #{@presto_home}"

unless @parsed[:cli_jar]
  @cli_jar = "s3://support.elasticmapreduce/bootstrap-actions/presto/versions/#{@parsed[:version]}/presto-cli-#{@parsed[:version]}-executable.jar"
else
  @cli_jar = @parsed[:cli_jar]
end

def run(cmd)
  if ! system(cmd) then
    raise "Command failed: #{cmd}"
  end
end

def sudo(cmd)
  run("sudo #{cmd}")
end

# First Install Java-1.8. If this is not present, nothing else will matter.
begin
  sudo "yum install java-1.8.0-openjdk-headless.x86_64 -y"
rescue
  puts "Failed to install Java 1.8, killing BA"
  puts $!, $@
  exit 1
end

def setupPrestoUser
  sudo "groupadd presto"
  sudo "useradd -d #{@presto_home} -g presto -m -s /bin/false presto"
  sudo "mkdir /mnt/var/log/presto"
  sudo "chown -R presto:presto /var/log/presto"
  sudo "chmod -R 755 /var/log/presto"
end

def getClusterMetaData
  metaData = {}
  jobFlow = JSON.parse(File.read('/mnt/var/lib/info/job-flow.json'))
  userData = JSON.parse(Net::HTTP.get(URI('http://169.254.169.254/latest/user-data/')))

  #Determine if Instance Has IAM Roles
  req = Net::HTTP.get_response(URI('http://169.254.169.254/latest/meta-data/iam/security-credentials/'))
  metaData['roles'] = (req.code.to_i == 200) ? true : false

  metaData['instanceId'] = Net::HTTP.get(URI('http://169.254.169.254/latest/meta-data/instance-id/'))
  metaData['instanceType'] = Net::HTTP.get(URI('http://169.254.169.254/latest/meta-data/instance-type/'))
  metaData['masterPrivateDnsName'] = jobFlow['masterPrivateDnsName']
  metaData['isMaster'] = userData['isMaster']

  return metaData
end

def determineMemory(type,parsed)
  puts parsed
  memory = {}

  if type.include? 'small'
    memory['xmx'] = "512M"
    memory['task_max_memory'] = "256MB"
  elsif type.include? 'medium'
    memory['xmx'] = "1G"
    memory['task_max_memory'] = "512MB"
  elsif type == 'r3.large'
    memory['xmx'] = "8G"
    memory['task_max_memory'] = "1GB"
  elsif type == 'r3.xlarge'
    memory['xmx'] = "16G"
    memory['task_max_memory'] = "2GB"
  elsif type == 'r3.2xlarge'
    memory['xmx'] = "32G"
    memory['task_max_memory'] = "4GB"
  else
    raise "Invalid instance type: #{type}"
  end

  if parsed[:xmx]
    memory['xmx'] = parsed[:xmx]
  end

  return memory
end

def setConfigProperties(metaData)
  config = []
  memory = determineMemory(metaData['instanceType'],@parsed)
  if metaData['isMaster'] == true
    config << 'coordinator=true'
  else
    config << 'coordinator=false'
  end

  config << "discovery.uri=http://#{metaData['masterPrivateDnsName']}:8080"
    #config << 'http-server.threads.max=500'
    config << 'task.shard.max-threads=8'
    config << 'discovery-server.enabled=true'
    config << 'sink.max-buffer-size=1GB'
    config << 'node-scheduler.include-coordinator=false'
    config << 'node-scheduler.location-aware-scheduling-enabled=false'
    config << "task.max-memory=#{memory['task_max_memory']}"
    config << 'query.max-history=1000'
    config << 'query.max-age=60m'
    config << 'http-server.http.port=8080'
    config << 'distributed-index-joins-enabled=true'
    config << 'distributed-joins-enabled'

    return config.join("\n")
end

def setHiveProperties(metaData,parsed)
  config = []

  config << 'hive.s3.connect-timeout=2m'
  config << "hive.s3.max-backoff-time=10m"
  config << "hive.s3.max-error-retries=50"
  config << "hive.s3.max-connections=500"
  config << "hive.s3.max-client-retries=50"
  config << "connector.name=hive-hadoop2"
  config << "hive.s3.socket-timeout=2m"
  config << "hive.allow-drop-table=true"
  config << "hive.allow-rename-table=true"

  #Set MetaStore Local Or Remote
  if !parsed[:metaURI]
    config << "hive.metastore.uri=thrift://#{metaData['masterPrivateDnsName']}:#{parsed[:port]}"
  else
    config << "hive.metastore.uri=#{parsed[:metaURI]}"
  end

  config << "hive.metastore-cache-ttl=20m"
  config << "hive.s3.staging-directory=/mnt/tmp/"
  config << "hive.s3.use-instance-credentials=#{metaData['roles']}"

  if parsed[:hiveConf]
    parsed[:hiveConf].split(',').each do | option |
      config << option
    end
  end

  puts "Setting Hive Catalog With the Following Properties:"
  puts config.join(" , ")
  return config.join("\n")
end

def setJVMConfig(metaData)
  config = []
  memory = determineMemory(metaData['instanceType'],@parsed)

  config << '-verbose:class'
  config << '-server'
  config << "-Xmx#{memory['xmx']}"
  config << "-XX:+UseConcMarkSweepGC"
  config << "-XX:+ExplicitGCInvokesConcurrent"
  config << "-XX:+CMSClassUnloadingEnabled"
  config << "-XX:+AggressiveOpts"
  config << "-XX:+HeapDumpOnOutOfMemoryError"
  config << "-XX:OnOutOfMemoryError=kill -9 %p"
  config << "-XX:ReservedCodeCacheSize=150M"
  config << "-Xbootclasspath/p:"
  config << "-XX:PermSize=150M"
  config << "-XX:MaxPermSize=150M"
  config << "-Dhive.config.resources=/etc/hadoop/conf/core-site.xml,/etc/hadoop/conf/hdfs-site.xml"
  config << "-Djava.library.path=/usr/lib/hadoop/lib/native/"

  return config.join("\n")
end

def setNodeConfig(metaData)
  config = []

  config << "node.data-dir=/var/log/presto"
  config << "node.id=#{metaData['instanceId']}"
  config << "node.environment=production"

  return config.join("\n")
end

def buildCLIWrapper
  config = []

  config << "#!/bin/bash"
  config << "export PATH=/usr/lib/jvm/jre-1.8.0-openjdk/bin:$PATH"
  config << "#{@presto_home}/presto-server-#{@parsed[:version]}/presto-cli-executable.jar $@"

  return config.join("\n")
end

def buildPrestoLauncher
  config = []

  config << "#!/bin/sh -eu"
  config << "export PATH=/usr/lib/jvm/jre-1.8.0-openjdk/bin:$PATH"
  config << 'exec "$(/usr/bin/dirname "$0")/launcher.py" "$@"'

  return config.join("\n")
end

def buildLogProperties
  config = []

  config << "com.facebook.presto=INFO"

  return config.join("\n")
end

def createRcScript
  open("/tmp/presto-server", 'w') do |f|
      f.write("
#!/bin/bash
#
# presto-server - this script starts and stops the presto-server daemon
#
# chkconfig:   345 90 10
# description: Presto Server
# pidfile:     /var/opt/presto/var/run/launcher.pid

daemon=\"/var/opt/presto/presto-server-#{@parsed[:version]}/bin/launcher\"
name=\"presto-server\"
user=\"presto\"

retval=0

start() {
  [ -x $presto_server ] || exit 5
  echo -n \"Starting $name: \"
  sudo -u $user $daemon start
  retval=$?
  return $retval
}

stop() {
  [ -x $presto_server ] || exit 5
  echo -n \"Stopping $name: \"
  sudo -u $user $daemon stop
  retval=$?
  return $retval
}

restart() {
  [ -x $presto_server ] || exit 5
  echo -n \"Restarting $name: \"
  sudo -u $user $daemon restart
  retval=$?
  return $retval
}

_kill() {
  [ -x $presto_server ] || exit 5
  echo -n \"Killing $name: \"
  sudo -u $user $daemon kill
  retval=$?
  return $retval
}

status() {
  [ -x $presto_server ] || exit 5
  sudo -u $user $daemon status
}

case \"$1\" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    kill)
        _kill
        ;;
    status)
        status
        ;;
    *)
        echo \"Usage: $name {start|stop|restart|kill|status}\"
        exit 1
        ;;
esac
exit $?
")
  end
  sudo "mv /tmp/presto-server /etc/init.d/presto-server"
  sudo "chown root:root /etc/init.d/presto-server"
  sudo "chmod 755 /etc/init.d/presto-server"
  sudo "chkconfig --add presto-server"
end

def launchPresto
  run "service presto-server start"
end

# create presto user
setupPrestoUser

# Get The Cluster Information Object
clusterMetaData = getClusterMetaData

# Now, Lets Fetch The Archives from S3
run "aws --region us-east-1 s3 cp #{@parsed[:binary]} /tmp/presto-server.tar.gz"

#Extract the Server to its new Home
if @user_binary == true
  @install_dir = File.dirname(@tmp_presto_home)
  run "mkdir -p #{@install_dir}"
  run "tar -xf /tmp/presto-server.tar.gz -C #{@install_dir}"
else
  @install_dir = File.dirname(@tmp_presto_home)
  run "mkdir -p #{@install_dir}"
  run "tar -xf /tmp/presto-server.tar.gz -C #{@install_dir}"
end

run "mkdir -p #{@tmp_presto_home}/etc/catalog/"

# Move LZO Library Into Presto Libs
run "aws --region us-east-1 s3 cp s3://support.elasticmapreduce/bootstrap-actions/presto/hadoop-lzo-0.4.19.jar #{@tmp_presto_home}/plugin/hive-hadoop2/"

# Fix Launcher For Java 8
open("#{@tmp_presto_home}/bin/launcher", 'w') do |f|
    f.puts(buildPrestoLauncher)
end

# Set config.properties
open("#{@tmp_presto_home}/etc/config.properties", 'w') do |f|
    f.puts(setConfigProperties(clusterMetaData))
end

# Set jvm.config
open("#{@tmp_presto_home}/etc/jvm.config", 'w') do |f|
    f.puts(setJVMConfig(clusterMetaData))
end

# Set Hive.config
open("#{@tmp_presto_home}/etc/catalog/hive.properties", 'w') do |f|
    f.puts(setHiveProperties(clusterMetaData,@parsed))
end

# Set node.properties
open("#{@tmp_presto_home}/etc/node.properties", 'w') do |f|
    f.puts(setNodeConfig(clusterMetaData))
end

# Set Log Properties
open("#{@tmp_presto_home}/etc/log.properties", 'w') do |f|
    f.puts(buildLogProperties)
end

createRcScript

# Create Presto Wrapper for CLI if CLI to be installed
if @parsed[:cli] == true
  run "aws --region us-east-1 s3 cp #{@cli_jar} /tmp/presto-cli-executable.jar"
  run "cp /tmp/presto-cli-executable.jar #{@tmp_presto_home}"
  run "chmod +x #{@tmp_presto_home}/presto-cli-executable.jar"
  if clusterMetaData['isMaster'] == true
    open("#{@tmp_presto_home}/bin/presto-cli", 'w') do |f|
        f.puts(buildCLIWrapper)
    end
    run "chmod +x #{@tmp_presto_home}/bin/presto-cli"
  end
end

# move presto directory to presto user directory
sudo "mv #{@tmp_presto_home} #{@presto_home}"
sudo "chown -R presto:presto #{@presto_home}"
sudo "chmod -R 755 #{@presto_home}"

# Set Symnlinkg For Presto to Home-Folder
if File.exist? "/home/hadoop/hive/bin/hive-init"
  run "rm -f home/hadoop/presto-server"
end

def launchMetaStoreLauncher
  open("/tmp/start-metastore", 'w') do |f|
      f.write("
        #!/bin/bash
      while true; do
      HIVE_SERVER=$(ps aux | grep hiveserver2 | grep -v grep | awk '{print $2}')
      if [ $HIVE_SERVER ]; then
              sleep 10
              echo Hive Server Running, Lets Check the Metastore
              STORE_PID=$(ps aux | grep -i metastore | grep -v grep | grep -v \"start-metastore\"| awk '{print $2}')
              if [ \"$STORE_PID\" ]; then
                      for pid in $STORE_PID; do
                              echo killing pid $pid
                              sudo kill -9 $pid
                      done
              fi
              echo Launching Metastore
              /home/hadoop/hive/bin/hive --service metastore -p #{@parsed[:port]} 2>&1 >> /var/log/apps/hive-metastore.log &
              exit 0
      fi
      echo Hive Server Not Running Yet
      sleep 10;
      done
      ")
  end
  run "chmod +x /tmp/start-metastore"
  run "/tmp/start-metastore 2>&1 >> /var/log/apps/meta-store-starter.log &"
end

# Set The MetaStore
if clusterMetaData['isMaster'] == true

  if !@parsed[:metaURI]
    launchMetaStoreLauncher
  end
end

#launchPresto
launchPresto

puts "If Nothing Went Wrong, You should now have a Latest Version of Presto Installed"

exit 0
