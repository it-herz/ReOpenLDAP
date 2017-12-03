#!/bin/bash

ulimit -n 1024
mkdir -p /home/ldap
chown -R ldap:ldap /home/ldap

mkdir -p /cache
chown -R ldap:ldap /cache

CONFIG_BASEDIR=/opt/reopenldap/etc/
CONFIG_FILE=$CONFIG_BASEDIR/slapd.conf
CONFIG_DIR=$CONFIG_BASEDIR/slapd.d
DATA_DIR=/opt/reopenldap/var/reopenldap-data

chown ldap:ldap -R $CONFIG_DIR
chmod 700 -R $CONFIG_DIR

chown ldap:ldap -R $DATA_DIR
chmod 700 -R $DATA_DIR

ACCESSLOG_DIR=/opt/reopenldap/var/accesslog

# Setup config directory

if [ ! -d $ACCESSLOG_DIR ]
then
  mkdir -p $ACCESSLOG_DIR
fi
chown -R ldap:ldap $ACCESSLOG_DIR

if [ ! -f $CONFIG_DIR/cn=config.ldif ]
then
  mkdir -p $CONFIG_DIR
  chown ldap:ldap -R $CONFIG_DIR
  chmod 700 -R $CONFIG_DIR

  mkdir -p $DATA_DIR
  chown ldap:ldap -R $DATA_DIR
  chmod 700 -R $DATA_DIR

# Setup config database
  echo "database config" >/tmp/slapd.conf
  echo 'rootdn "cn=admin,cn=config"' >>/tmp/slapd.conf
  ENC_PASSWORD="`slappasswd -h {ssha} -s $CONFIG_PASSWORD`"
  echo "rootpw $ENC_PASSWORD" >>/tmp/slapd.conf
  echo "access to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break" >>/tmp/slapd.conf

  runuser -l ldap -c "/opt/reopenldap/sbin/slaptest -f /tmp/slapd.conf -F $CONFIG_DIR"

# Setup domain database
  sed -i "s~^suffix.*$~suffix \"$LDAP_SUFFIX\"~g" $CONFIG_FILE
  sed -i "s~^rootdn.*$~rootdn \"$ROOT_DN\"~g" $CONFIG_FILE

  ENC_PASSWORD="`slappasswd -h {ssha} -s $ROOT_PASSWORD`"

  sed -i "s~^rootpw.*$~rootpw $ENC_PASSWORD~g" $CONFIG_FILE

  echo "access to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break" >>$CONFIG_FILE

  cp /opt/schemas/* /opt/etc/reopenldap/schema/

  echo "Initializing domain"
  /opt/reopenldap/sbin/slapd -h "ldap://$HOSTNAME ldaps://$HOSTNAME ldapi:///" -u ldap -g ldap -d $LDAP_LOG_LEVEL -f $CONFIG_FILE &
  PID=$!
  sleep 1
  kill $PID
  sleep 1

  runuser -l ldap -c "/opt/reopenldap/sbin/slaptest -f $CONFIG_FILE -F $CONFIG_DIR"

  /opt/reopenldap/sbin/slapd -h "ldap://$HOSTNAME ldaps://$HOSTNAME ldapi:///" -u ldap -g ldap -d $LDAP_LOG_LEVEL -F /opt/reopenldap/etc/slapd.d &
  PID=$!
  sleep 1

  #register overlays
  ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/modules.ldif


  #Syncrepl for data
  ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/syncprov.ldif

  declare -i rid
  rid=1

  OLD_IFS="$IFS"
  IFS=";"
  cp /opt/schema_repl_db_header.ldif /tmp/schema_repl_db.ldif
  for REPLHOST in $REPL_HOSTS
  do
    export RID=`printf "%03d\n" $rid`
    export HOST=$REPLHOST
    cat /opt/schema_repl_db_data.ldif | envsubst >>/tmp/schema_repl_db.ldif
    rid=rid+1
  done
  echo "-" >>/tmp/schema_repl_db.ldif
  cat /opt/mirror.ldif >>/tmp/schema_repl_db.ldif
  IFS="$OLD_IFS"

  ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/schema_repl_db.ldif
  #rm /tmp/schema_repl_db.ldif

  #Syncrepl for config (schema and metadata)
  ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/syncprovdb.ldif

  OLD_IFS="$IFS"
  IFS=";"
  cp /opt/schema_repl_header.ldif /tmp/schema_repl.ldif
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

  sleep 1
  kill $PID
fi

/opt/reopenldap/sbin/slapd -c rid=001 -h "ldap://$HOSTNAME ldaps://$HOSTNAME ldapi:///" -u ldap -g ldap -d $LDAP_LOG_LEVEL -F /opt/reopenldap/etc/slapd.d &
#switch to mirror mode
ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/mirror.ldif

PID=$!
sleep 1

#Convert additional schemas
for EXTSCHEMA in `ls -1 /opt/schemas/*.schema`
do
#  ES=${EXTSCHEMA#*-}
  echo "include $EXTSCHEMA" >/tmp/schemas.conf
  echo "Converting schema $EXTSCHEMA"
  echo 'runuser -l ldap -c "/opt/reopenldap/sbin/slaptest -f /tmp/schemas.conf -F $CONFIG_DIR"'
  runuser -l ldap -c "/opt/reopenldap/sbin/slaptest -f /tmp/schemas.conf -F $CONFIG_DIR"
done

cp /opt/schemas/*.ldif $CONFIG_BASEDIR/schema/

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
#rm /tmp/tls.ldif

cat /opt/maxsize.ldif | envsubst >/tmp/maxsize.ldif
ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/maxsize.ldif

IFS=","
#Add additional schemas
for SCHEMA in $SCHEMAS
do
  if [ -f $CONFIG_BASEDIR/schema/$SCHEMA.ldif ]
  then
    ldapadd -c -H ldapi:// -Y EXTERNAL -f $CONFIG_BASEDIR/schema/$SCHEMA.ldif
    echo "Schema $SCHEMA is registered"
  fi
done

#RefInt Configuration
ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/refint.ldif

#memberof overlay
ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/memberof.ldif

#chain overlay
#ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/chain.ldif

#accesslog overlay
cat /opt/accesslogdb.ldif | envsubst >/tmp/accesslogdb.ldif
ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/accesslogdb.ldif

ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/accesslog.ldif

#cache
ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/pcache.ldif
ldapadd -H ldapi:/// -Y EXTERNAL -f /opt/pcachedb.ldif

#Modify LDAPs
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
echo "olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break" >>/tmp/access.ldif
ldapadd -H ldapi:// -Y EXTERNAL -f /tmp/access.ldif

export FPDOMAIN=herzen
cat /opt/domain.ldif | envsubst >/tmp/domain.ldif
ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/domain.ldif

export PASSWORD="`slappasswd -h {ssha} -s $ROOT_PASSWORD`"
export FROOTDN=admin
cat /opt/admin.ldif | envsubst >/tmp/admin.ldif
ldapadd -H ldapi:/// -Y EXTERNAL -f /tmp/admin.ldif

#Generate index
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


kill $PID
echo "Running"
/opt/reopenldap/sbin/slapd -h "ldap://$HOSTNAME ldaps://$HOSTNAME ldapi:///" -u ldap -g ldap -d $LDAP_LOG_LEVEL -F /opt/reopenldap/etc/slapd.d
