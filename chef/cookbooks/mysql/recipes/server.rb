#
# Cookbook Name:: mysql
# Recipe:: default
#
# Copyright 2008-2011, Opscode, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "mysql::client"
include_recipe "database::client"

ha_enabled = node[:database][:ha][:enabled]

# For Crowbar, we need to set the address to bind - default to admin node.
addr = node["mysql"]["bind_address"] || ""
newaddr = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
if addr != newaddr
  node["mysql"]["bind_address"] = newaddr
  node.save
end

package "mysql-server" do
  package_name "mysql" if node[:platform_family] == "suse"
  action :install
end

case node[:platform_family]
when "rhel", "fedora"
  mysql_service_name = "mysqld"
else
  mysql_service_name = "mysql"
end

service "mysql" do
  service_name mysql_service_name
  supports status: true, restart: true, reload: true, restart_crm_resource: true if ha_enabled
  action :enable
  provider Chef::Provider::CrowbarPacemakerService if ha_enabled
end

directory node[:mysql][:tmpdir] do
  owner "mysql"
  group "mysql"
  mode "0700"
  action :create
end

script "handle mysql restart" do
  interpreter "bash"
  action :nothing
  code <<EOC
service mysql stop
rm /var/lib/mysql/ib_logfile?
service mysql start
EOC
end

cluster_nodes = CrowbarPacemakerHelper.cluster_nodes(node)
nodes_names = cluster_nodes.map { |n| n[:hostname] }
cluster_addresses = "gcomm://" + nodes_names.join(",")

template "/etc/my.cnf.d/openstack.cnf" do
  source "my.cnf.erb"
  owner "root"
  group "mysql"
  mode "0640"
  notifies :restart, "service[mysql]", :immediately
end

if node[:database][:ha][:enabled]
  unless node[:database][:galera_bootstrapped]
    # For bootstrapping sst, use root with no password
    template "/etc/my.cnf.d/galera.cnf" do
      source "galera.cnf.erb"
      owner "root"
      group "mysql"
      mode "0640"
      variables(
        cluster_addresses: cluster_addresses,
        sstuser: "root",
        sstuser_password: ""
      )
      notifies :restart, "service[mysql]", :immediately
    end
  end
end

unless Chef::Config[:solo]
  ruby_block "save node data" do
    block do
      node.save
    end
    action :create
  end
end

if ha_enabled
  log "HA support for mysql is enabled"
  include_recipe "mysql::ha_galera"
else
  log "HA support for mysql is disabled"
end

server_root_password = node[:mysql][:server_root_password]

execute "assign-root-password" do
  command "/usr/bin/mysqladmin -u root password \"#{server_root_password}\""
  action :run
  not_if { ha_enabled } # password already set as part of the ha bootstrap
  only_if "/usr/bin/mysql -u root -e 'show databases;'"
end

db_settings = fetch_database_settings
db_connection = db_settings[:connection].dup
db_connection[:host] = "localhost"
db_connection[:username] = "root"
db_connection[:password] = node[:database][:mysql][:server_root_password]

unless node[:database][:database_bootstrapped]
  database_user "create db_maker database user" do
    connection db_connection
    username "db_maker"
    password node[:database][:db_maker_password]
    host "%"
    provider db_settings[:user_provider]
    action :create
    only_if { !ha_enabled || CrowbarPacemakerHelper.is_cluster_founder?(node) }
  end

  database_user "create haproxy and galera monitoring user" do
    connection db_connection
    username "monitoring"
    password ""
    host "%"
    provider db_settings[:user_provider]
    action :create
    only_if { ha_enabled && CrowbarPacemakerHelper.is_cluster_founder?(node) }
  end

  database_user "grant db_maker access" do
    connection db_connection
    username "db_maker"
    password node[:database][:db_maker_password]
    host "%"
    privileges db_settings[:privs] + [
      "ALTER ROUTINE",
      "CREATE ROUTINE",
      "CREATE TEMPORARY TABLES",
      "CREATE USER",
      "CREATE VIEW",
      "EXECUTE",
      "GRANT OPTION",
      "LOCK TABLES",
      "RELOAD",
      "SHOW DATABASES",
      "SHOW VIEW",
      "TRIGGER"
    ]
    provider db_settings[:user_provider]
    action :grant
    only_if { !ha_enabled || CrowbarPacemakerHelper.is_cluster_founder?(node) }
  end

  database "drop test database" do
    connection db_connection
    database_name "test"
    provider db_settings[:provider]
    action :drop
    only_if { !ha_enabled || CrowbarPacemakerHelper.is_cluster_founder?(node) }
  end

  database_user "drop anonymous database user" do
    connection db_connection
    username ""
    host "*"
    provider db_settings[:user_provider]
    action :drop
    only_if { !ha_enabled || CrowbarPacemakerHelper.is_cluster_founder?(node) }
  end

  if node[:database][:ha][:enabled]
    database_user "create state snapshot transfer user" do
      connection db_connection
      username "sstuser"
      password node[:database][:mysql][:sstuser_password]
      host "localhost"
      provider db_settings[:user_provider]
      action :create
      only_if { ha_enabled && CrowbarPacemakerHelper.is_cluster_founder?(node) }
    end

    database_user "grant sstuser root privileges" do
      connection db_connection
      username "sstuser"
      password node[:database][:mysql][:sstuser_password]
      host "localhost"
      provider db_settings[:user_provider]
      action :grant
      only_if { ha_enabled && CrowbarPacemakerHelper.is_cluster_founder?(node) }
    end
  end
end

if node[:database][:ha][:enabled]
  # Ensure we are syncronised so that the sstuser is on the node
  crowbar_pacemaker_sync_mark "sync-database_before_cnf_update" do
    revision node[:database]["crowbar-revision"]
  end

  # Update galera.cnf with new user details
  template "/etc/my.cnf.d/galera.cnf" do
    source "galera.cnf.erb"
    owner "root"
    group "mysql"
    mode "0640"
    variables(
      cluster_addresses: cluster_addresses,
      sstuser: "sstuser",
      sstuser_password: node[:database][:mysql][:sstuser_password]
    )
    notifies :restart, "service[mysql]", :immediately
  end
end

ruby_block "mark node for database bootstrap" do
  block do
    node.set[:database][:database_bootstrapped] = true
    node.save
  end
  not_if { node[:database][:database_bootstrapped] }
end

directory "/var/log/mysql/" do
  owner "mysql"
  group "root"
  mode "0755"
  action :create
end

directory "/var/run/mysqld/" do
  owner "mysql"
  group "root"
  mode "0755"
  action :create
end
