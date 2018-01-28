#!/bin/bash

# Define environment
ulimit -n 2048
mkdir -p /home/ldap
chown -R ldap:ldap /home/ldap

CONFIG_BASEDIR=/opt/reopenldap/etc/
CONFIG_FILE=$CONFIG_BASEDIR/slapd.conf
CONFIG_DIR=$CONFIG_BASEDIR/slapd.d
DATA_DIR=/opt/reopenldap/var/reopenldap-data
ACCESSLOG_DIR=/opt/reopenldap/var/accesslog

# Fix permissions
mkdir -p $CONFIG_DIR
chown ldap:ldap -R $CONFIG_DIR
chmod 700 -R $CONFIG_DIR

mkdir -p $DATA_DIR
chown ldap:ldap -R $DATA_DIR
chmod 700 -R $DATA_DIR

export ENC_CONFIG_PASSWORD="$(slappasswd -h {ssha} -s $CONFIG_PASSWORD)"
export ENC_ROOT_PASSWORD="$(slappasswd -h {ssha} -s $ROOT_PASSWORD)"
export ENC_REPLICATOR_PASSWORD="$(slappasswd -h {ssha} -s $REPLICATOR_PASSWORD)"

# First boot - raw initialization
if [ ! -f $CONFIG_DIR/cn=config.ldif ]
then
# Setup config database
  echo "database config" >/tmp/slapd.conf
  echo 'rootdn "cn=admin,cn=config"' >>/tmp/slapd.conf
  echo "rootpw $ENC_CONFIG_PASSWORD" >>/tmp/slapd.conf
  echo "access to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break" >>/tmp/slapd.conf
  echo "crash-backtrace on" >>/tmp/slapd.conf
  runuser -l ldap -c "/opt/reopenldap/sbin/slaptest -f /tmp/slapd.conf -F $CONFIG_DIR"

# Setup domain database
  sed -i "s~^suffix.*$~suffix \"$LDAP_SUFFIX\"~g" $CONFIG_FILE
  sed -i "s~^rootdn.*$~rootdn \"$ROOT_DN\"~g" $CONFIG_FILE
  sed -i "s~^rootpw.*$~rootpw $ENC_ROOT_PASSWORD~g" $CONFIG_FILE
  sed -i "/^index.*$/d" $CONFIG_FILE
  echo "access to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break" >>$CONFIG_FILE

# Initializing domain
  cp /opt/schemas/* /opt/reopenldap/etc/schema/
  /opt/reopenldap/sbin/slapd -h "ldap://$HOSTNAME ldaps://$HOSTNAME ldapi:///" -u ldap -g ldap -d "$LDAP_LOG_LEVEL" -f "$CONFIG_FILE" &
  PID=$!
  sleep 3
  kill $PID
  sleep 1

# Convert configuration to config backend
  runuser -l ldap -c "/opt/reopenldap/sbin/slaptest -f $CONFIG_FILE -F $CONFIG_DIR"

# Apply new configuration
  /opt/reopenldap/sbin/slapd -h "ldap://$HOSTNAME ldaps://$HOSTNAME ldapi:///" -u ldap -g ldap -d "$LDAP_LOG_LEVEL" -F "$CONFIG_DIR" &
  PID=$!
  sleep 5

  #register overlays

  # Register cache overlay (if needed)
  if [ "$ENABLE_CACHE" == "1" ] && [ "$MODE" != "REPLICA" ]
  then
    mkdir -p /cache
    chown -R ldap:ldap /cache
    echo "olcModuleLoad: pcache" >>/opt/modules.ldif
  fi

  # Register accesslog overlay (if needed)
  if [ "$ENABLE_ACCESSLOG" == "1" ]
  then
     # Setup accesslog directory

     mkdir -p $ACCESSLOG_DIR
     chown -R ldap:ldap $ACCESSLOG_DIR
     echo "olcModuleLoad: accesslog" >>/opt/modules.ldif
  fi
  
  # Register modules
  ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/modules.ldif

  if [ "$MODE" != "REPLICA" ]
    then

    #RefInt Configuration
    ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/refint.ldif

    #memberof overlay
    ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/memberof.ldif

    #ServerSideSort
    ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/sssvlv.ldif

    #Audit log
    ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/audit.ldif

    if [ "$ENABLE_ACCESSLOG" == "1" ]
    then
      cat /opt/accesslogdb.ldif | envsubst >/tmp/accesslogdb.ldif
      ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/accesslogdb.ldif
      ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/accesslog.ldif
    fi

    if [ "$ENABLE_CACHE" == "1" ]
    then
    #cache
      ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/pcache.ldif
      ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/pcachedb.ldif
    fi
  fi

  if [ "$ENABLE_MONITOR" == "1" ]
  then
    cat /opt/monitoring.ldif | envsubst >/tmp/monitoring.ldif
    ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/monitoring.ldif
  fi

  sleep 1

  kill $PID
fi

if [ "$MODE" != "RAW" ]
then

# Reconfiguration in normal node
  /opt/reopenldap/sbin/slapd -h "ldap://$HOSTNAME ldaps://$HOSTNAME ldapi:///" -u ldap -g ldap -d "$LDAP_LOG_LEVEL" -F "$CONFIG_DIR" &
  PID=$!
  sleep 1

  #switch to mirror mode
  ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/mirror.ldif

  if [ "$MODE" == "BOOTSTRAP" ] || [ "$MODE" == "REPLICA" ]
  then
#Convert additional schemas
    for EXTSCHEMA in $(ls -1 /opt/schemas/*.schema)
    do
      EXTSCHEMA_NAME=`echo $EXTSCHEMA | sed 's~.*/[[:digit:]]*\-\(.*\)~\1~ig'`
      cp $EXTSCHEMA /tmp/$EXTSCHEMA_NAME
      echo "include /tmp/$EXTSCHEMA_NAME" >/tmp/schemas.conf
      echo "Converting schema $EXTSCHEMA_NAME"
      cat /tmp/schemas.conf
      runuser -l ldap -c "/opt/reopenldap/sbin/slaptest -v -f /tmp/schemas.conf -F /tmp"
    done

  fi

  cp -R $CONFIG_BASEDIR/schema/ $CONFIG_DIR/

  for A in `ls -1 /tmp/cn=config/cn=schema`
  do
    P=`echo $A | sed 's~cn={0}\(.*\)~\1~ig'`
    cat /tmp/cn=config/cn=schema/$A | grep -v entryUUID | grep -v entryCSN | grep -v creatorsName | grep -v createTimestamp | grep -v modifiersName | grep -v modifyTimestamp | grep -v structuralObjectClass | sed 's/dn:\(.*\)/\1,cn=schema,cn=config/' >$CONFIG_DIR/schema/$P
  done
  cp -R /tmp/cn=config/cn=schema/*.ldif $CONFIG_DIR/cn=config/cn=schema

  #Register modules

  #Add TLS configuration
  cat /opt/tls.ldif | envsubst >/tmp/tls.ldif
  IFS=";"
  declare -i id
  id=1
  for REPLHOST in $REPL_HOSTS
  do
    echo "olcServerID: $id ldap://$REPLHOST" >>/tmp/tls.ldif
    id=id+1
  done

  ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/tls.ldif

  IFS=","
#Add additional schemas
  for SCHEMA in $SCHEMAS
  do
    echo "=============================================================="
    echo "Processing schema $SCHEMA"
    echo "=============================================================="
  
    if [ -f $CONFIG_DIR/schema/$SCHEMA.ldif ]
    then
      ldapadd -c -H ldapi:// -Y EXTERNAL -f $CONFIG_DIR/schema/$SCHEMA.ldif
      echo "Schema $SCHEMA is registered"
    fi
  done

  chmod 777 -R $CONFIG_DIR/cn=config/cn=schema

  if [ "$MODE" != "REPLICA" ]
  then
  #Override search size limit to unlimited by default
    echo "dn: olcDatabase={-1}frontend,cn=config" >/tmp/limit.ldif
    echo "changetype: modify" >>/tmp/limit.ldif
    echo "replace: olcSizeLimit" >>/tmp/limit.ldif
    echo "olcSizeLimit: -1" >>/tmp/limit.ldif
    ldapadd -H ldapi:// -Y EXTERNAL -f /tmp/limit.ldif

    echo "dn: olcDatabase={1}mdb,cn=config" >/tmp/limit.ldif
    echo "changetype: modify" >>/tmp/limit.ldif
    echo "replace: olcSizeLimit" >>/tmp/limit.ldif
    echo "olcSizeLimit: -1" >>/tmp/limit.ldif
    ldapadd -H ldapi:// -Y EXTERNAL -f /tmp/limit.ldif

  # redefine max size
    echo "dn: olcDatabase={1}mdb,cn=config" >/tmp/limital.ldif
    echo "changetype: modify" >>/tmp/limital.ldif
    echo "replace: olcDbMaxSize" >>/tmp/limital.ldif
    echo "olcDbMaxSize: $MAXSIZE" >>/tmp/limital.ldif
    ldapadd -H ldapi:// -Y EXTERNAL -f /tmp/limital.ldif
  fi

  if [ "$ENABLE_ACCESSLOG" == "1" ] 
  then
  # If define access log - redefine max size
    echo "dn: olcDatabase={2}mdb,cn=config" >/tmp/limital.ldif
    echo "changetype: modify" >>/tmp/limital.ldif
    echo "replace: olcDbMaxSize" >>/tmp/limital.ldif
    echo "olcDbMaxSize: $MAXSIZE" >>/tmp/limital.ldif
    ldapadd -H ldapi:// -Y EXTERNAL -f /tmp/limital.ldif
  fi

  #Modify ACL
  echo "dn: olcDatabase={1}mdb,cn=config" >/tmp/access.ldif
  echo "changetype: modify" >>/tmp/access.ldif
  echo "replace: olcAccess" >>/tmp/access.ldif
  IFS=";"
  if [ ! -z "$ACL" ]
  then
    for ACCESS in $ACL
    do
      echo "olcAccess: {0}$ACCESS" >>/tmp/access.ldif
    done
  fi
  if [ "$ENABLE_ACCESSLOG" == "1" ]
  then
    cat /opt/accesslog_acl.ldif | envsubst >/tmp/accesslog_acl.ldif
    cat /tmp/accesslog_acl.ldif >>/tmp/access.ldif
  fi

  echo "olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by dn.exact=uid=replicator,$LDAP_SUFFIX manage by * break" >>/tmp/access.ldif
  ldapadd -H ldapi:// -Y EXTERNAL -f /tmp/access.ldif

  #Generate index
  if [ "$MODE" != "NORMAL" ]
  then
    OLD_IFS=$IFS
    IFS=";"
    for IV in $INDEXES
    do
      export INDEX=$IV
      cat /opt/index.ldif | envsubst >/tmp/index.ldif
      ldapadd -H ldapi:// -Y EXTERNAL -f /tmp/index.ldif
      echo "Index created for $INDEX"
    done
    IFS=$OLD_IFS
  fi

  #Build directory stub
  if [ "$MODE" == "REPLICA" ] || [ "$MODE" == "BOOTSTRAP" ]
  then
    export FPDOMAIN="$(echo $LDAP_SUFFIX | sed 's/dc=\([^,]*\).*/\1/')"
    cat /opt/domain.ldif | envsubst >/tmp/domain0.ldif
    ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/domain0.ldif

    export PASSWORD="$ENC_ROOT_PASSWORD"
    export FROOTDN="$(echo $ROOT_DN | sed 's/cn=\([^,]*\).*/\1/')"
    cat /opt/admin.ldif | envsubst >/tmp/admin0.ldif
    ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/admin0.ldif

    cat /opt/services.ldif | envsubst >/tmp/services.ldif
    ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/services.ldif

    cat /opt/replicator.ldif | envsubst >/tmp/replicator.ldif
    ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/replicator.ldif

    # Apply replication
    # Syncrepl for data
    ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/syncprov.ldif

    # Build servers list and rid records
    declare -i rid
    rid=1

    OLD_IFS="$IFS"
    IFS=";"
    cat /opt/schema_repl_db_header.ldif | envsubst >/tmp/schema_repl_db.ldif
    for REPLHOST in $REPL_HOSTS
    do
      export RID=`printf "%03d\n" $rid`
      export HOST=$REPLHOST
      cat /opt/schema_repl_db_data.ldif | envsubst >>/tmp/schema_repl_db.ldif
      rid=rid+1
    done
    echo "-" >>/tmp/schema_repl_db.ldif
    # Turn on mirror mode
    cat /opt/mirror.ldif >>/tmp/schema_repl_db.ldif
    IFS="$OLD_IFS"

    ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/schema_repl_db.ldif

    #Syncrepl for config (schema and metadata)
    ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/syncprovdb.ldif

    OLD_IFS="$IFS"
    IFS=";"
    cat /opt/schema_repl_header.ldif | envsubst >/tmp/schema_repl.ldif
    for REPLHOST in $REPL_HOSTS
    do
      export RID=`printf "%03d\n" $rid`
      export HOST=$REPLHOST
      cat /opt/schema_repl_data.ldif | envsubst >>/tmp/schema_repl.ldif
      rid=rid+1
    done
    IFS="$OLD_IFS"
    echo "-" >>/tmp/schema_repl.ldif
    cat /opt/mirror.ldif >>/tmp/schema_repl.ldif
    ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/schema_repl.ldif
  fi

  sleep 1

  kill $PID

  echo "Running"

  if [ ! -z "$INITFILE" ]
    then
    cat $INITFILE | slapadd -v -F $CONFIG_DIR
  fi
fi

if [ "$REINDEX" == "1" ] && [ "$MODE" != "REPLICA" ]
then
  echo "Reindexing"
  /opt/reopenldap/sbin/slapindex -v
fi

#Autorestart in case of error or failure
while [ 1 ]
do
  declare -i BEFORE=`date +%s`
  /opt/reopenldap/sbin/slapd -h "ldap://$HOSTNAME ldaps://$HOSTNAME ldapi:///" -u ldap -g ldap -D -d "$LDAP_LOG_LEVEL" -F "$CONFIG_DIR"
  declare -i AFTER=`date +%s`
  declare -i INTERVAL
  INTERVAL=AFTER-BEFORE
  echo "Duration $INTERVAL"
  if [ $INTERVAL -lt 60 ]
  then
# Too fast restarts, quit
    exit 1
  fi
done
