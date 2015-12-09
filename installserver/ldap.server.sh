#!/bin/bash

scriptPath=$(cd `dirname $0`; pwd)

if [ $UID -ne 0 ]
then
	echo "Use \"sudo\" to run this, or switch to root to run this."
	exit 1
fi

if [ x"$DOMAIN" == x ]
then
	DOMAIN=example.com
fi

DC=$(echo $DOMAIN| sed 's/^/dc=/' | sed 's/\./,dc=/g')
if [ x"$FIRST_USER_LAST_NAME" == x ]
then
	FIRST_USER_LAST_NAME=tse
fi
if [ x"$FIRST_USER_FIRST_NAME" == x ]
then
	FIRST_USER_FIRST_NAME=simon
fi
if [ x"$FIRST_USER_LOGIN" == x ]
then
	FIRST_USER_LOGIN=$(echo $FIRST_USER_FIRST_NAME | awk '{print tolower($0)}').$(echo $FIRST_USER_LAST_NAME | awk '{print tolower($0)}')
fi


section="# ----- [ LDAP ] ----- #"
echo "$section"

# https://help.ubuntu.com/lts/serverguide/openldap-server.html
## sudo apt-get remove --purge slapd
sudo apt-get -q -y install slapd ldap-utils ldapvi

if ! [ -f /etc/ssl/certs/$DOMAIN.crt ]
then
	sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/$DOMAIN.key -out /etc/ssl/certs/$DOMAIN.crt
fi

cat <<EOF | sudo tee /etc/phpldapadmin/nginx.conf
server {
        listen       80;
        server_name  ldap.$DOMAIN;
        rewrite ^ https://\$http_host\$request_uri? permanent;    # force redirect http to https
}
server {
  listen                *:443 ssl;

  server_name           ldap.$DOMAIN;
  ssl                   on;
  ssl_certificate       /etc/ssl/certs/$DOMAIN.crt;
  ssl_certificate_key   /etc/ssl/private/$DOMAIN.key;
  ssl_protocols         TLSv1 TLSv1.1 TLSv1.2;
  ssl_session_timeout 5m;

  ssl_ciphers EECDH+aRSA+AES256:EDH+aRSA+AES256:EECDH+aRSA+AES128:EDH+aRSA+AES128;
  ssl_session_cache shared:SSL:1m;
  ssl_prefer_server_ciphers on;
  add_header Strict-Transport-Security max-age=63072000;

  access_log            /var/log/nginx/ssl.ldap.$DOMAIN.access.log main;
  root /usr/share/phpldapadmin/htdocs/;
  index index.php index.html index.htm;

  location ~ \.php\$ {
        fastcgi_intercept_errors        on;
        error_page 404 /error/404.php;
        fastcgi_pass php-fpm-backend;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header        X-Real-IP       \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
EOF
sudo ln -sfn /etc/phpldapadmin/nginx.conf /etc/nginx/sites-available/ldap.$DOMAIN.conf
sudo ln -sfn /etc/nginx/sites-available/ldap.$DOMAIN.conf /etc/nginx/sites-enabled/ldap.$DOMAIN.conf
sudo service nginx reload

sudo dpkg-reconfigure slapd
# ldapsearch -x -LLL -H ldap:/// -b dc=example,dc=com dn

# ldapsearch -x -LLL -b dc=example,dc=com 'uid=john' cn gidNumber
tmp=$(mktemp -d /tmp/XXXXXX)
touch $tmp/company.ldif
cat <<EOF > $tmp/company.ldif
dn: ou=Users,$DC
objectClass: organizationalUnit
ou: Users

dn: ou=Groups,$DC
objectClass: organizationalUnit
ou: Groups

dn: cn=IT,ou=Groups,$DC
objectClass: posixGroup
cn: it
gidNumber: 7001

dn: uid=$FIRST_USER_LOGIN,ou=Users,$DC
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: $FIRST_USER_LOGIN
sn: $FIRST_USER_LOGIN
givenName: $FIRST_USER_FIRST_NAME
cn: $FIRST_USER_FIRST_NAME $FIRST_USER_LAST_NAME
displayName: $FIRST_USER_FIRST_NAME $FIRST_USER_LAST_NAME
uidNumber: 8001
gidNumber: 8001
userPassword: hello123
gecos: $FIRST_USER_FIRST_NAME $FIRST_USER_LAST_NAME
loginShell: /bin/bash
homeDirectory: /home/$FIRST_USER_LOGIN
EOF

echo "Setup basic Users and Groups, and first user:"
ldapadd -x -D cn=admin,$DC -W -f $tmp/company.ldif

# sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f logging.ldif


rm -rf $tmp
