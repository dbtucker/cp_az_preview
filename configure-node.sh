#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
# Script to deploy and configure the Confluent Platform packages
# as part of a total cluster deployment operation into Azure.
#
# Expectations :
#	Script run as root
#	Confluent Platform already installed to $CP_HOME (with proper ownerships)
#
# Input
#	HOSTNAME : System hostname determines core functionality
#	CLUSTERNAME : (currently extracted from hostname as ${host%%-*}
#	DATA_DIRS : space-separated list of directories for Kafka Log data
#	CP_HOSTS_FILE : file (defaults to /tmp/cphosts) deployed hosts
#		Fixed naming schema: <cluster>-[broker | zookeeper | worker]
#	CP_PARM file (defaults to /tmp/cp.parm), containing
#		zknodes: list of Zookeeper hostnames
#		brokers: list of nodes to run Kafka brokers
#			NOTE: will be constructed based on /tmp/cfhosts if necessary
#
# Output
#	Services configured and running
#	Schema Registry service runs on *broker-1
#	REST Proxy service runs on all broker nodes 
#
# Future enhancements
#	- Better integratio with Linux service model (so that Kafka services
#		can be part of core O/S
#	- Put an HAProxy service in front of REST Proxy
#	
#

set -x

THIS_SCRIPT=`readlink -f $0`
SCRIPTDIR=`dirname ${THIS_SCRIPT}`

LOG=/tmp/configure-node.log

# Extract useful details from the AWS MetaData
# The information there should be treated as the source of truth,
# even if the internal settings are temporarily incorrect.
murl_top=http://169.254.169.254/latest/meta-data

THIS_FQDN=$(curl -f $murl_top/hostname)
[ -z "${THIS_FQDN}" ] && THIS_FQDN=`hostname --fqdn`
THIS_HOST=${THIS_FQDN%%.*}
CLUSTERNAME="${THIS_HOST%%-*}"

CP_HOSTS_FILE=/tmp/cphosts    # Helper file

# Our configuration files (default locations {tarball installation})
CP_HOME=/opt/confluent
ZK_CFG=$CP_HOME/etc/kafka/zookeeper.properties
BROKER_CFG=$CP_HOME/etc/kafka/server.properties
REST_PROXY_CFG=${CP_HOME}/etc/kafka-rest/kafka-rest.properties
SCHEMA_REG_CFG=$CP_HOME/etc/schema-registry/schema-registry.properties
KAFKA_CONNECT_CFG=$CP_HOME/etc/kafka/connect-distributed.properties
LEGACY_CONSUMER_CFG=$CP_HOME/etc/kafka/consumer.properties
LEGACY_PRODUCER_CFG=$CP_HOME/etc/kafka/producer.properties
CONTROL_CENTER_CFG=$CP_HOME/etc/confluent-control-center/control-center.properties

CONF_SCHEMA_CLASS='io.confluent.kafka.schemaregistry.rest.SchemaRegistryMain'
CONF_REST_CLASS='io.confluent.kafkarest.KafkaRestMain'


# Several startup scripts (at least as of 3.0.0) are pretty crippled.
# Need to make sure they correctly support output files during nohup launches
#	(and the control center startup script doesn't even support the daemon mode)
patch_confluent_service_scripts() {
	BIN_DIR=$CP_HOME/bin

	if [ -f $BIN_DIR/kafka-run-class ] ; then 
		grep -q '${CONSOLE_OUTPUT_FILE:-${LOG_DIR}/krc_daemon.out}' $BIN_DIR/kafka-run-class
		[ $? -ne 0 ] && sed -i '/DAEMON_MODE="true"/a CONSOLE_OUTPUT_FILE=${CONSOLE_OUTPUT_FILE:-${LOG_DIR}/krc_daemon.out}' $BIN_DIR/kafka-run-class
	fi

	if [ -f $BIN_DIR/schema-registry-run-class ] ; then 
		grep -q "srrc_daemon.out" $BIN_DIR/schema-registry-run-class
		[ $? -ne 0 ] && sed -i "s|< /dev/null|< /dev/null > \${base_dir}/logs/srrc_daemon.out|" $BIN_DIR/schema-registry-run-class
	fi

	if [ -f $BIN_DIR/kafka-rest-run-class ] ; then 
		grep -q "krrc_daemon.out" $BIN_DIR/kafka-rest-run-class
		[ $? -ne 0 ] && sed -i "s|< /dev/null|< /dev/null > \${base_dir}/logs/krrc_daemon.out|" $BIN_DIR/kafka-rest-run-class
	fi

	if [ -f $BIN_DIR/control-center-run-class ] ; then 
		grep -q "ccrc_daemon.out" $BIN_DIR/control-center-run-class
		[ $? -ne 0 ] && sed -i "s|< /dev/null|< /dev/null > \${base_dir}/logs/ccrc_daemon.out|" $BIN_DIR/control-center-run-class
	fi

		# Handle daemon option in connect-distributed
	if [ -f $BIN_DIR/connect-distributed ] ; then 
		grep -q "DAEMON_ARG" $BIN_DIR/connect-distributed
		if [ $? -ne 0 ] ; then
			sed -i '/^export CLASSPATH$/a [ \$1 == "-daemon" ] && DAEMON_ARG=-daemon && shift ' $BIN_DIR/connect-distributed
			sed -i 's|kafka-run-class|kafka-run-class ${DAEMON_ARG:-}|' $BIN_DIR/connect-distributed
		fi
	fi

		# Add daemon option to control-center-start
		#	Kludge for initial confluent platform release
		#	NOTE: the "-daemon" arg is handeld differently for the control-center-run-class script !!!
	if [ -x $BIN_DIR/control-center-start ] ; then 
		grep -e 'run-class io.confluent.controlcenter.ControlCenter \"\$props_file\"' $BIN_DIR/control-center-start
		if [ $? -eq 0 ] ; then
			sed -i '/^props_file=/a [ $props_file == "-daemon" ] && DAEMON_ARG=-daemon && props_file=${2}' $BIN_DIR/control-center-start
			sed -i 's|run-class io.confluent.controlcenter.ControlCenter|run-class io.confluent.controlcenter.ControlCenter ${DAEMON_ARG:-}|' $BIN_DIR/control-center-start
		fi
	fi
}

# For now, make sure initscripts directory and service scripts
# are owned by root
patch_confluent_initscripts() {
	INITSCRIPTS_DIR=${CP_HOME}/initscripts
	INITSCRIPTS_LIST="cp-kafka-service cp-zk-service cp-schema-service cp-rest-service control-center-service"

	if [ -d $INITSCRIPTS_DIR ] ; then
		chown -R --reference=/etc/init.d $INITSCRIPTS_DIR
	else
		mkdir -p $INITSCRIPTS_DIR 
#		chown --reference=$CP_HOME/etc $INITSCRIPTS_DIR
	fi

		# Distribute patches to the image if necessary.
	for s in $INITSCRIPTS_LIST ; do
		if [ -f ${SCRIPTDIR}/$s ] ; then
			if [ -f ${INITSCRIPTS_DIR}/$s ] ; then
				cp -p ${INITSCRIPTS_DIR}/$s ${INITSCRIPTS_DIR}/${s}.image
			fi

			cp ${SCRIPTDIR}/$s ${INITSCRIPTS_DIR}
			chmod a+x ${INITSCRIPTS_DIR}/${s}
#			chown --reference=${INITSCRIPTS_DIR} $INITSCRIPTS_DIR/${s}
		fi
	done
}

# Archive the configuration file sto a known location
archive_cfg() {
	NOW=$(date +"%F-%H:%M")
	backup_dir=$CP_HOME/etc/archive_${NOW}
	mkdir -p $backup_dir

	cp -p $ZK_CFG $backup_dir
	cp -p $BROKER_CFG $backup_dir
	cp -p $REST_PROXY_CFG $backup_dir
	cp -p $SCHEMA_REG_CFG $backup_dir
	cp -p $KAFKA_CONNECT_CFG $backup_dir
	cp -p $LEGACY_CONSUMER_CFG $backup_dir
	cp -p $CONTROL_CENTER_CFG $backup_dir
}

# Add/update config file parameter
#	$1 : config file
#	$2 : property
#	$3 : new value
#	$4 (optional) : 0: delete old value; 1[default]: retain old value 
#
# The sed logic in this functions works given following limitations
#	1. At most one un-commented setting for a given parameter
#	2. If ONLY commented values exist, the FIRST ONE will be overwritten
#
set_property() {
	[ ! -f $1 ] && return 1

	local cfgFile=$1
	local property=$2
	local newValue=$3
	local doArchive=${4:-1}

	grep -q "^${property}=" $cfgFile
	overwriteMode=$?

	grep -q "^#${property}=" $cfgFile
	restoreMode=$?


	if [ $overwriteMode -eq 0 ] ; then
		if [ $doArchive -ne 0 ] ; then
				# Add the new setting, then comment out the old
			sed -i "/^${property}=/a ${property}=$newValue" $cfgFile
			sed -i "0,/^${property}=/s|^${property}=|# ${property}=|" $cfgFile
		else
			sed -i "s|^${property}=.*$|${property}=${newValue}|" $cfgFile
		fi
	elif [ $restoreMode -eq 0 ] ; then
				# "Uncomment" first entry, then replace it
				# This helps us by leaving the setting in the same place in the file
		sed -i "0,/^#${property}=/s|^#${property}=|${property}=|" $cfgFile
		sed -i "s|^${property}=.*$|${property}=${newValue}|" $cfgFile
	else 
		echo "" >> $cfgFile
		echo "${property}=${newValue}" >> $cfgFile

	fi
}



# TBD
#	Be smarter about updating config
configure_confluent_zk() {
	[ ! -f $ZK_CFG ] && return 1
	
	grep -q ^initLimit $ZK_CFG
	[ $? -ne 0 ] && echo "initLimit=5" >> $ZK_CFG

	grep -q ^syncLimit $ZK_CFG
	[ $? -ne 0 ] && echo "syncLimit=2" >> $ZK_CFG

	myid=0
	zidx=1
	for znode in ${zknodes//,/ } ; do
		set_property $ZK_CFG "server.$zidx" "$znode:2888:3888" 0
		[ $znode = $THIS_HOST ] && myid=$zidx
		zidx=$[zidx+1]
	done

		# If we're not a ZK node, there's nothing more to do
	echo $zknodes | grep -q -w $THIS_HOST
	[ $? -ne 0 ] && return 0

		# Simple deployment : ZK data in $CP_HOME/zkdata
	mkdir -p $CP_HOME/zkdata
	chown --reference=$CP_HOME/etc $CP_HOME/zkdata

	set_property $ZK_CFG "dataDir" "$CP_HOME/zkdata"

	if [ $myid -gt 0 ] ; then
		echo $myid > $CP_HOME/zkdata/myid
		chown --reference=$CP_HOME/etc $CP_HOME/zkdata/myid
	fi
}

configure_kafka_broker() {
	[ ! -f $BROKER_CFG ] && return 1

	local ncpu=$(grep ^processor /proc/cpuinfo | wc -l)
	ncpu=${ncpu:-2}

	myid=0
	bidx=1
	for bnode in ${brokers//,/ } ; do
		[ $bnode = $THIS_HOST ] && myid=$bidx
		bidx=$[bidx+1]
	done

#		No need to set broker.id so long as auto-generation is
#		enabled (which it is by default)
#	if [ $myid -gt 0 ] ; then
#		sed -i "s/^broker\.id=.*$/broker\.id=$myid/" $BROKER_CFG
#	fi
#
#		Instead, comment out explicit setting and force auto-generation
	sed -i "s/^broker\.id=/# broker\.id=$myid/" $BROKER_CFG
	sed -i "s/^broker\.id\.generation\.enabled=false/broker\.id\.generation\.enabled=true/" $BROKER_CFG

		# Set target zookeeper quorum and VERY LONG timeout
		# (since we don't know how long before other nodes will come on line)
	set_property $BROKER_CFG "zookeeper.connect" "$zconnect"
	set_property $BROKER_CFG "zookeeper.connection.timeout.ms" 300000

	if [ -n "$DATA_DIRS" ] ; then
		for d in $DATA_DIRS ; do
			chown --reference=$CP_HOME/etc $d
		done

		set_property $BROKER_CFG "log.dirs" "${DATA_DIRS// /,}"
		set_property $BROKER_CFG "num.recovery.threads.per.data.dir" $[ncpu*4]

			# Could also bump num.io.threads (default: 8) and
			# num.network.threads (default: 3) here.
	fi

		# Enable graceful leader migration
	set_property $BROKER_CFG "controlled.shutdown.enable" "true"

		# For tracking activity in the cloud.
	set_property $BROKER_CFG "confluent.support.customer.id" "Azure_BYOL"
}

configure_schema_registry() {
	[ ! -f $SCHEMA_REG_CFG ] && return 1

	set_property $SCHEMA_REG_CFG "kafkastore.connection.url" "$zconnect"
	set_property $SCHEMA_REG_CFG "kafkastore.zk.session.timeout.ms" "300000"
	set_property $SCHEMA_REG_CFG "kafkastore.init.timeout.ms" "300000"
}

configure_rest_proxy() {
	[ ! -f $REST_PROXY_CFG ] && return 1

	set_property $REST_PROXY_CFG "id" "kafka-rest-${CLUSTERNAME}" 0

		# TBD : get much smarter about Schema Registry Port
		# Should grab this from zookeeper if it's available
	sru="${brokers%%,*}"
	sru="http://${sru%:*}:8081"
	set_property $REST_PROXY_CFG "schema.registry.url" "$sru" 0
	set_property $REST_PROXY_CFG "zookeeper.connect" "$zconnect" 0
}

configure_control_center() {
	[ ! -f $CONTROL_CENTER_CFG ] && return 1

	local numBrokers=`echo ${brokers//,/ } | wc -w`

	cc_topics_replicas=3
	[ $cc_topics_replicas -gt $numBrokers ] && cc_topics_replicas=$numBrokers

	monitoring_topics_replicas=2
	[ $monitoring_topics_replicas -gt $numBrokers ] && monitoring_topics_replicas=$numBrokers

	cc_partitions=5
	[ $cc_partitions -gt $numBrokers ] && cc_partitions=$numBrokers

		# Update properties for the Control Center
	set_property $CONTROL_CENTER_CFG "bootstrap.servers" "$bconnect" 0
	set_property $CONTROL_CENTER_CFG "zookeeper.connect" "$zconnect" 0

	set_property $CONTROL_CENTER_CFG "confluent.controlcenter.internal.topics.partitions" $cc_partitions
	set_property $CONTROL_CENTER_CFG "confluent.controlcenter.internal.topics.replication" $cc_topics_replicas
	set_property $CONTROL_CENTER_CFG "confluent.monitoring.interceptor.topic.partitions" $cc_partitions
	set_property $CONTROL_CENTER_CFG "confluent.monitoring.interceptor.topic.replication" $monitoring_topics_replicas

		# Should be handled better ... the set of all workers.
#	set_property $CONTROL_CENTER_CFG "confluent.controlcenter.connect.cluster" "localhost:8083" 0

		# Put control center data on larger storage (if configured)
	if [ -n "$DATA_DIRS" ] ; then
		for d in $DATA_DIRS ; do
			chown --reference=$CP_HOME/etc $d
			[ -z "$CC_DATA_DIR" ] && CC_DATA_DIR=${d}/confluent/control-center
		done

		set_property $CONTROL_CENTER_CFG "confluent.controlcenter.data.dir" "${CC_DATA_DIR}"
	fi

		# Control Center requires a separate Kafka Connect cluster
	CC_CONNECT_CFG=$CP_HOME/etc/confluent-control-center/connect-cc.properties
	cp -p $CP_HOME/etc/schema-registry/connect-avro-distributed.properties $CC_CONNECT_CFG

	set_property $CC_CONNECT_CFG "consumer.interceptor.classes" "io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor" 0
	set_property $CC_CONNECT_CFG "producer.interceptor.classes" "io.confluent.monitoring.clients.interceptor.MonitoringProducerInterceptor" 0

	set_property $CC_CONNECT_CFG "key.converter.schema.registry.url" "http://$srconnect" 0
	set_property $CC_CONNECT_CFG "value.converter.schema.registry.url" "http://$srconnect" 0

		# Set the data location to the last disk in our list
	[ -n "$DATA_DIRS" ] && set_property $CC_CONNECT_CFG "confluent.controlcenter.data.dir" "${DATA_DIRS##* }"
}

configure_workers() {
	if [ -f $LEGACY_CONSUMER_CFG ] ; then
		set_property $LEGACY_CONSUMER_CFG "group.id" "${CLUSTERNAME}-consumer-group"
		set_property $LEGACY_CONSUMER_CFG "zookeeper.connect" "$zconnect"
		set_property $LEGACY_CONSUMER_CFG "zookeeper.connection.timeout.ms" 30000
		set_property $LEGACY_CONSUMER_CFG "interceptor.classes" "io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor" 
	fi

	if [ -f $LEGACY_PRODUCER_CFG ] ; then
		set_property $LEGACY_PRODUCER_CFG "bootstrap.servers" "${bconnect}"
		set_property $LEGACY_PRODUCER_CFG "request.timeout.ms" "100"
		set_property $LEGACY_PRODUCER_CFG "interceptor.classes" "io.confluent.monitoring.clients.interceptor.MonitoringProducerInterceptor" 
	fi

		# We'll default to the Avro converters since we know
		# we'll have the Schema Registry .   Also enable the 
		# interceptors for Control Center Monitoring
	if [ -f $KAFKA_CONNECT_CFG ] ; then
		set_property $KAFKA_CONNECT_CFG "group.id" "${CLUSTERNAME}-connect-cluster"
		set_property $KAFKA_CONNECT_CFG "bootstrap.servers" "${bconnect}"

		set_property $KAFKA_CONNECT_CFG  "key.converter" "io.confluent.connect.avro.AvroConverter"
		set_property $KAFKA_CONNECT_CFG  "key.converter.schema.registry.url" "http://${srconnect}"
		set_property $KAFKA_CONNECT_CFG  "value.converter" "io.confluent.connect.avro.AvroConverter"
		set_property $KAFKA_CONNECT_CFG  "value.converter.schema.registry.url" "http://${srconnect}"

		set_property $KAFKA_CONNECT_CFG  "consumer.interceptor.classes" "io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor" 
		set_property $KAFKA_CONNECT_CFG  "producer.interceptor.classes" "io.confluent.monitoring.clients.interceptor.MonitoringProducerInterceptor" 
	fi

		# There are multiple "connect-*.properties" files in
		# the schema registry location that need to be updated as well
	for f in $CP_HOME/etc/schema-registry/connect-*.properties ; do
		set_property $f "bootstrap.servers" "${bconnect}" 0
		set_property $f "key.converter.schema.registry.url" "http://${srconnect}" 0
		set_property $f "value.converter.schema.registry.url" "http://${srconnect}" 0
	done

	for f in $CP_HOME/etc/schema-registry/*-distributed.properties ; do
		set_property $KAFKA_CONNECT_CFG "group.id" "${CLUSTERNAME}-connect-cluster" 0
	done
}

#
# Sets several important variables for use in sub-functions
#	zconnect : zookeeper connect arg (<host1>:<port1>[,<host2>:<port2> ...]
#	bconnect : broker connect arg (<host1>:<port1>[,<host2>:<port2> ...]
#	srconnect : schema registry connect arg (<host1>:<port1>[,<host2>:<port2> ...]
#
configure_confluent_node() {
		# Assemble Zookeeper Connect and Broker List strings  once, 
		# since we may use themm in multiple places
	if [ -f $ZK_CFG ] ; then 
		eval $(grep ^clientPort= $ZK_CFG)
		zkPort=${clientPort:-2181}
	fi

	zconnect=""
	for znode in ${zknodes//,/ } ; do
		if [ -z "$zconnect" ] ; then
			zconnect="$znode:${zkPort:-2181}"
		else
			zconnect="$zconnect,$znode:${zkPort:-2181}"
		fi
	done

	if [ -f $BROKER_CFG ] ; then 
		eval $(grep ^listeners= $BROKER_CFG)
		brokerPort=${listeners##*:}
		brokerPort=${brokerPort:-9092}
	fi

	bconnect=""
	for bnode in ${brokers//,/ } ; do
		if [ -z "$bconnect" ] ; then
			bconnect="$bnode:${brokerPort:-9092}"
		else
			bconnect="$bconnect,$bnode:${brokerPort:-9092}"
		fi
	done

		# Schema Registry runs on the first broker
	srconnect=${brokers%%,*}:8081

	if [ -f $KAFKA_CONNECT_CFG ] ; then 
		connectRestPort=$(grep -e ^rest.port= $KAFKA_CONNECT_CFG | cut -d'=' -f2)
		connectRestPort=${connectRestPort:-8083}
	fi

	wconnect=""
	for wnode in ${workers//,/ } ; do
		if [ -z "$wconnect" ] ; then
			wconnect="$wnode:${connectRestPort:-8083}"
		else
			wconnect="$wconnect,$wnode:${connectRestPort:-8083}"
		fi
	done

	archive_cfg

	configure_confluent_zk
	configure_kafka_broker
	configure_schema_registry
	configure_rest_proxy

	configure_workers 
	[ -n "$workers" ] && configure_control_center
}

resolve_zknodes() {
    echo "WAITING FOR DNS RESOLUTION of zookeeper nodes {$zknodes}" >> $LOG
    zkwait=600
    zkready=0
    while [ $zkready -eq 0 ]
    do
        [ $zkwait -lt 0 ] && return 1

        zkready=1
        echo testing DNS resolution for zknodes
        for i in ${zknodes//,/ }
        do
            [ -z "$(dig -t a +search +short $i)" ] && zkready=0
        done

        echo zkready is $zkready
        [ $zkready -eq 0 ] && sleep 5
        zkwait=$[zkwait - 5]
    done
    echo "DNS has resolved all zknodes {$zknodes}" >> $LOG
    return 0
}

# Kludgy function to make sure the cluster is formed before
# proceeding with the remaining startup activities.
#
#	NOTE: We only need to wait for other brokers if THIS NODE
#		is a broker or worker.  zookeeper-only nodes need not 
#		waste time here
wait_for_brokers() {
	echo "$brokers" | grep -q -w "$THIS_HOST" 
	if [ $? -ne 0 ] ; then
		echo "$workers" | grep -q -w "$THIS_HOST" 
		[ $? -ne 0 ] && return 0
	fi


    BROKER_WAIT=${1:-300}

    SWAIT=$BROKER_WAIT
    STIME=5
    ${CP_HOME}/bin/kafka-topics --list --zookeeper ${zconnect} &> /dev/null
    while [ $? -ne 0  -a  $SWAIT -gt 0 ] ; do
        sleep $STIME
        SWAIT=$[SWAIT - $STIME]
    	${CP_HOME}/bin/kafka-topics --list --zookeeper ${zconnect} &> /dev/null
    done

	[ $SWAIT -le 0 ] && return 1

		# Now that we know the ZK cluster is on line, we can check the number
		# of registered brokers.  Ideally, we'd just look for "enough" brokers,
		# hence the "targetBrokers" logic below
		#
	local numBrokers=`echo ${brokers//,/ } | wc -w`
	local targetBrokers=$numBrokers
	[ $targetBrokers -gt 5 ] && targetBrokers=5

	local runningBrokers=$( echo "ls /brokers/ids" | $CP_HOME/bin/zookeeper-shell ${zconnect%%,*} | grep '^\[' | tr -d "[:punct:]" | wc -w )
    while [ ${runningBrokers:-0} -lt $targetBrokers  -a  $SWAIT -gt 0 ] ; do
        sleep $STIME
        SWAIT=$[SWAIT - $STIME]
		runningBrokers=$( echo "ls /brokers/ids" | $CP_HOME/bin/zookeeper-shell ${zconnect%%,*} | grep '^\[' | tr -d "[:punct:]" | wc -w )
    done

	[ $SWAIT -le 0 ] && return 1

	return 0
}



# Use hostname to determine services to start
# Configure appropriate services for auto-start
#
#	DANGER : the systemctl logic needs the control
#	operations to run from the SAME LOCATION.  You
#	cannot start with "$CP_HOME/initscripts/cp-*-service"
#	and then stop with "/etc/init.d/cp-*-service"
#
start_node_services() {
	BIN_DIR=$CP_HOME/bin

	echo "$zknodes" | grep -q -w "$THIS_HOST" 
	if [ $? -eq 0 ] ; then
		if [ -x $CP_HOME/initscripts/cp-zk-service ] ; then
			ln -s  $CP_HOME/initscripts/cp-zk-service  /etc/init.d
			chkconfig cp-zk-service on
			[ $? -ne 0 ] && systemctl enable cp-zk-service

#			$CP_HOME/initscripts/cp-zk-service start
#			/etc/init.d/cp-zk-service start
			service cp-zk-service start
		else
			$BIN_DIR/zookeeper-server-start -daemon $ZK_CFG
		fi
	fi

	echo "$brokers" | grep -q -w "$THIS_HOST" 
	if [ $? -eq 0 ] ; then
		if [ -x $CP_HOME/initscripts/cp-kafka-service ] ; then
			ln -s  $CP_HOME/initscripts/cp-kafka-service  /etc/init.d
			chkconfig cp-kafka-service on
			[ $? -ne 0 ] && systemctl enable cp-kafka-service

#			$CP_HOME/initscripts/cp-kafka-service start
#			/etc/init.d/cp-kafka-service start
			service cp-kafka-service start
		else
			$BIN_DIR/kafka-server-start -daemon $BROKER_CFG
		fi
	fi

		# Very rudimentary function to wait for brokers to come on-line
	wait_for_brokers

		# Schema registy on first broker only
	if [ ${brokers%%,*} = $THIS_HOST ] ; then
		if [ -x $CP_HOME/initscripts/cp-schema-service ] ; then
			ln -s  $CP_HOME/initscripts/cp-schema-service  /etc/init.d
			chkconfig cp-schema-service on
			[ $? -ne 0 ] && systemctl enable cp-schema-service

#			$CP_HOME/initscripts/cp-schema-service start
#			/etc/init.d/cp-schema-service start
			service cp-schema-service start
		else
			$(cd $BIN_DIR/../logs; $BIN_DIR/schema-registry-run-class $CONF_SCHEMA_CLASS -daemon $SCHEMA_REG_CFG > /dev/null)
		fi
	fi

	echo "$brokers" | grep -q -w "$THIS_HOST" 
	if [ $? -eq 0 ] ; then
		if [ -x $CP_HOME/initscripts/cp-rest-service ] ; then
			ln -s  $CP_HOME/initscripts/cp-rest-service  /etc/init.d
			chkconfig cp-rest-service on
			[ $? -ne 0 ] && systemctl enable cp-rest-service

#			$CP_HOME/initscripts/cp-rest-service start
#			/etc/init.d/cp-rest-service start
			service cp-rest-service start
		else
			$(cd $BIN_DIR/../logs; $BIN_DIR/kafka-rest-run-class $CONF_REST_CLASS -daemon $REST_PROXY_CFG > /dev/null)
		fi
	fi

	echo "$workers" | grep -q -w "$THIS_HOST" 
	if [ $? -eq 0 ] ; then
		if [ -x $CP_HOME/initscripts/cp-connect-service ] ; then
			ln -s  $CP_HOME/initscripts/cp-connect-service  /etc/init.d
			chkconfig cp-connect-service on
			[ $? -ne 0 ] && systemctl enable cp-connect-service

#			$CP_HOME/initscripts/cp-connect-service start
#			/etc/init.d/cp-connect-service start
			service cp-connect-service start
		else
			$BIN_DIR/connect-distributed -daemon $KAFKA_CONNECT_CFG
		fi
	fi
}

start_control_center() {
	BIN_DIR=$CP_HOME/bin

		# Control Center on first broker only
		# Control Center is VERY FRAGILE on start-up,
		#	so we'll try a second time if the first try fails.
	if [ "${workers%%,*}" = $THIS_HOST ] ; then
		if [ -x $CP_HOME/initscripts/control-center-service ] ; then
			ln -s  $CP_HOME/initscripts/control-center-service  /etc/init.d
			chkconfig control-center-service on
			[ $? -ne 0 ] && systemctl enable control-center-service

#			$CP_HOME/initscripts/control-center-service start
#			/etc/init.d/control-center-service start
			service control-center-service start
			[ $? -ne 0 ] && service control-center-service start
		else
			$(cd $BIN_DIR/../logs; $BIN_DIR/control-center-start -daemon $CONTROL_CENTER_CFG > /dev/null)
		fi
	fi
}

main() 
{
	echo "$0 script started at "`date` >> $LOG

	if [ `id -u` -ne 0 ] ; then
		echo "	ERROR: script must be run as root" >> $LOG
		exit 1
	fi

		# Look for the parameter file that will have the 
		# variables necessary to complete the installation
	CP_PARM_FILE=/tmp/cp.parm
	if [ -f $CP_PARM_FILE ] ; then
		. $CP_PARM_FILE
	elif [ -r "${CP_HOSTS_FILE:-/tmp/NO_SUCH_FILE}" ] ; then
		if [ -r /tmp/gen-cluster-hosts.log ] ; then
			grep -q "could not resolve" /tmp/gen-cluster-hosts.log
			if [ $? -eq 0 ] ; then
				echo "	WARNING: incomplete DNS support of cluster nodes (see /tmp/gen-cluster-hosts.log)" | tee -a  $LOG
			fi
		fi

		bhosts=`grep -e "-broker-" $CP_HOSTS_FILE | awk '{print $1}' `
		if [ -n "bhosts" ] ; then
			brokers=`echo $bhosts`			# convert <\n> to ' '
		fi
		brokers=${brokers// /,}

			# Use specified ZK's or the first 1|3 brokers
		zkhosts=`grep -e "-zk-" $CP_HOSTS_FILE | awk '{print $1}' `
		if [ -n "$zkhosts" ] ; then
			zknodes=`echo $zkhosts`			# convert <\n> to ' '
		else
			nbrokers=`echo $bhosts | wc -w`
			if [ $nbrokers -lt 3 ] ; then
				zknodes=${brokers%%,*}
			else
				zknodes=`echo $bhosts | awk '{print $1","$2","$3}'`
			fi
		fi
		zknodes=${zknodes// /,}		# not really necessary ... but safe

			# external workers
		whosts=`grep -e "-worker-" $CP_HOSTS_FILE | awk '{print $1}' `
		if [ -n "whosts" ] ; then
			workers=`echo $whosts`			# convert <\n> to ' '
		fi
		workers=${workers// /,}

	else
		return 1
	fi
		
	if [ -z "${zknodes}"  -o  -z "${brokers}" ] ; then
	    echo "Insufficient specification for Confluent Platform cluster ... terminating script" >> $LOG
		exit 1
	fi

		# And make sure DATA_DIRS is set.   If it is not 
		# passed in, we can simply look for all "data*" directories
		# in $CP_HOME
	if [ -z "$DATA_DIRS" ] ; then
		DATA_DIRS=`ls -d $CP_HOME/data*`
	fi

	patch_confluent_service_scripts
	patch_confluent_initscripts

	configure_confluent_node
	
	resolve_zknodes
	if [ $? -eq 0 ] ; then
		start_node_services
		[ -n "$workers" ] && start_control_center 
	fi

	echo "$0 script finished at "`date` >> $LOG
}



main $@
exitCode=$?

set +x

exit $exitCode

