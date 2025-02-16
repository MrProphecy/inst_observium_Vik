#!/usr/bin/env bash
#
# install_observium.sh
#
# Script para instalar Observium Community Edition en Rocky Linux
# usando el paquete oficial .tar.gz, sin depender del repositorio Git.
#
# Ejecución:
#   chmod +x install_observium.sh
#   ./install_observium.sh
#

# ========================
#    CONFIGURACIÓN
# ========================
DB_ROOT_PASS="MiPasswordRootSQL"       # Contraseña root de MariaDB (si no está configurada, la establecemos).
OBS_DB_NAME="observium"                # Nombre de la base de datos para Observium
OBS_DB_USER="observium"                # Usuario de la base de datos
OBS_DB_PASS="MiPasswordObservium"      # Contraseña del usuario de la base de datos

OBS_ADMIN_USER="admin"                 # Usuario admin para Observium
OBS_ADMIN_PASS="MiPasswordAdmin"       # Contraseña admin para Observium

SERVER_NAME="observium.local"          # Host o dominio. Ej: observium.ejemplo.com
INSTALL_DIR="/opt/observium"           # Carpeta donde instalaremos Observium
PHP_TIMEZONE="Europe/Madrid"           # Ajustar a tu zona horaria

OBS_TGZ_URL="http://www.observium.org/observium-community-latest.tar.gz"

# ========================
#     1) PREPARAR SO
# ========================
echo "1) Actualizando el sistema y paquetes base..."
dnf -y update

echo "Instalando dependencias (Apache, PHP, MariaDB, SNMP, etc.)..."
dnf -y install epel-release
dnf -y install httpd mariadb mariadb-server net-snmp net-snmp-utils \
               php php-cli php-mysqlnd php-gd php-xml php-snmp php-json \
               php-zip php-common php-mbstring ImageMagick rrdtool fping \
               unzip cronie wget

systemctl enable --now httpd mariadb crond

# ========================
#    2) CONFIGURAR MYSQL
# ========================
echo "2) Configurando MariaDB..."
# A) Opcional: Automatizar mysql_secure_installation con 'expect'.
#    Solo si quieres forzar la contraseña root y eliminar users de prueba.
if ! mysql -u root -p"$DB_ROOT_PASS" -e "status" &>/dev/null; then
  echo "Intentando establecer contraseña root de MariaDB..."
  dnf -y install expect || true

  SECURE_MYSQL=$(expect -c "
set timeout 10
spawn mysql_secure_installation
expect \"Enter current password for root*\"
send \"\r\"
expect \"Switch to unix_socket*\"
send \"n\r\"
expect \"Set root password?\"
send \"y\r\"
expect \"New password:\"
send \"$DB_ROOT_PASS\r\"
expect \"Re-enter new password:\"
send \"$DB_ROOT_PASS\r\"
expect \"Remove anonymous users?\"
send \"y\r\"
expect \"Disallow root login remotely?\"
send \"y\r\"
expect \"Remove test database*\"
send \"y\r\"
expect \"Reload privilege tables*\"
send \"y\r\"
expect eof
")
  echo "$SECURE_MYSQL"
fi

# B) Crear la base de datos y usuario de Observium
echo "Creando base de datos [$OBS_DB_NAME] y usuario [$OBS_DB_USER]..."
mysql -u root -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS $OBS_DB_NAME CHARACTER SET utf8 COLLATE utf8_general_ci;"
mysql -u root -p"$DB_ROOT_PASS" -e "CREATE USER IF NOT EXISTS '$OBS_DB_USER'@'localhost' IDENTIFIED BY '$OBS_DB_PASS';"
mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON $OBS_DB_NAME.* TO '$OBS_DB_USER'@'localhost';"
mysql -u root -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"

# ========================
#   3) DESCARGAR OBSERVIUM
# ========================
echo "3) Descargando Observium Community .tar.gz..."
mkdir -p "$INSTALL_DIR"
cd /opt

# Bajamos el tar y extraemos
wget -O observium-latest.tar.gz "$OBS_TGZ_URL"
tar xvfz observium-latest.tar.gz

# Normalmente se extrae en "observium" o "observium-community"; ajustamos si es distinto
# Si ya trae la carpeta "observium", podemos renombrarla:
if [ -d "observium" ]; then
  mv observium "$INSTALL_DIR"
else
  # Si la carpeta se llama "observium-community", etc.
  mv observium-community "$INSTALL_DIR" 2>/dev/null || true
fi

cd "$INSTALL_DIR"

# ========================
#    4) CONFIGURAR OBSERVIUM
# ========================
echo "Copiando config.php y editando..."
cp config.php.default config.php

# Editamos las líneas de la DB en config.php
sed -i "s|\$config\['db_host'\] = 'localhost';|\$config['db_host'] = 'localhost';|g" config.php
sed -i "s|\$config\['db_user'\] = 'observium';|\$config['db_user'] = '$OBS_DB_USER';|g" config.php
sed -i "s|\$config\['db_pass'\] = 'observium';|\$config['db_pass'] = '$OBS_DB_PASS';|g" config.php
sed -i "s|\$config\['db_name'\] = 'observium';|\$config['db_name'] = '$OBS_DB_NAME';|g" config.php

echo "\$config['php_timezone'] = '$PHP_TIMEZONE';" >> config.php

echo "Inicializando la base de datos Observium..."
./discovery.php -u || true
./discovery.php -h all || true
./validate.php || true

echo "Creando usuario admin [$OBS_ADMIN_USER]..."
./adduser.php $OBS_ADMIN_USER $OBS_ADMIN_PASS 10

# ========================
#    5) APACHE + SELINUX
# ========================
echo "Configurando VirtualHost de Apache..."
cat <<EOF > /etc/httpd/conf.d/observium.conf
<VirtualHost *:80>
  DocumentRoot $INSTALL_DIR/html/
  ServerName $SERVER_NAME

  <Directory "$INSTALL_DIR/html/">
    AllowOverride All
    Require all granted
  </Directory>

  ErrorLog /var/log/httpd/observium_error.log
  CustomLog /var/log/httpd/observium_access.log combined
</VirtualHost>
EOF

echo "Ajustando permisos y SELinux..."
chown -R apache:apache "$INSTALL_DIR"

if sestatus | grep -q "enforcing"; then
  dnf -y install policycoreutils-python-utils || true
  semanage fcontext -a -t httpd_sys_rw_content_t "$INSTALL_DIR(/.*)?"
  restorecon -RF "$INSTALL_DIR"
fi

systemctl restart httpd

# ========================
# 6) MENSAJE FINAL
# ========================
echo "---------------------------------------------------"
echo " Observium Community se instaló en: $INSTALL_DIR"
echo " Accede en: http://$SERVER_NAME/"
echo " Usuario admin: $OBS_ADMIN_USER"
echo " Contraseña:    $OBS_ADMIN_PASS"
echo " Base de datos: $OBS_DB_NAME (Usuario: $OBS_DB_USER)"
echo "---------------------------------------------------"
echo "Si SELinux está habilitado, revisa que no bloquee."
echo "¡Listo! Observium debería estar activo."

