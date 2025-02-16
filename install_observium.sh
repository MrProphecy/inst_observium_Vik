#!/usr/bin/env bash
#
# install_observium.sh
#
# Script para instalar Observium Community Edition en Rocky Linux (8/9).
# Requiere ejecución como root o sudo.
# Ejemplo de uso:
#   chmod +x install_observium.sh
#   ./install_observium.sh
#

# ==================================================
#  CONFIGURACIÓN (puedes cambiar estas variables)
# ==================================================
DB_ROOT_PASS="MiPasswordRootSQL"       # Contraseña root de MariaDB (si no existe, la estableceremos)
OBS_DB_NAME="observium"                # Nombre de la base de datos para Observium
OBS_DB_USER="observium"                # Usuario de la base de datos
OBS_DB_PASS="MiPasswordObservium"      # Contraseña del usuario de la base de datos
OBS_ADMIN_USER="admin"                 # Nombre de usuario admin en Observium
OBS_ADMIN_PASS="MiPasswordAdmin"       # Contraseña para el usuario admin de Observium
SERVER_NAME="observium.local"          # Nombre de host o dominio
INSTALL_DIR="/opt/observium"           # Directorio donde se clonará Observium
PHP_TIMEZONE="Europe/Madrid"           # Ajustar a tu zona horaria (ej: America/Bogota, Europe/Madrid, etc.)

# ==================================================
#    1. PREPARACIÓN DEL SISTEMA
# ==================================================
set -e  # Si ocurre un error, el script se detendrá
echo "Actualizando el sistema..."
dnf -y update

echo "Instalando paquetes básicos (EPEL, Apache, PHP, MariaDB, SNMP, etc.)..."
dnf -y install epel-release
dnf -y install httpd mariadb mariadb-server net-snmp net-snmp-utils \
               php php-cli php-mysqlnd php-gd php-xml php-snmp php-json \
               php-zip php-common php-mbstring ImageMagick rrdtool git fping unzip cronie

systemctl enable --now httpd mariadb crond

# ==================================================
#    2. CONFIGURAR MARIADB
# ==================================================
echo "Configurando MariaDB..."

# A) Establecer contraseña root de MariaDB (si no está puesta).
#    Usamos 'expect' para automatizar mysql_secure_installation (opcional).
if [ -x "$(command -v expect)" ]; then
  echo "Instalando expect para configurar MariaDB..."
  dnf -y install expect
  SECURE_MYSQL=$(expect -c "
set timeout 5
spawn mysql_secure_installation
expect \"Enter current password for root (enter for none):\"
send \"\r\"
expect \"Switch to unix_socket authentication\"
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
expect \"Remove test database and access to it?\"
send \"y\r\"
expect \"Reload privilege tables now?\"
send \"y\r\"
expect eof
")
  echo "$SECURE_MYSQL"
else
  echo "No se encontró 'expect'. Configura manualmente con 'mysql_secure_installation' si es necesario."
fi

# B) Crear base de datos y usuario Observium
echo "Creando base de datos y usuario para Observium..."
mysql -u root -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS $OBS_DB_NAME CHARACTER SET utf8 COLLATE utf8_general_ci;"
mysql -u root -p"$DB_ROOT_PASS" -e "CREATE USER IF NOT EXISTS '$OBS_DB_USER'@'localhost' IDENTIFIED BY '$OBS_DB_PASS';"
mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON $OBS_DB_NAME.* TO '$OBS_DB_USER'@'localhost';"
mysql -u root -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"

# ==================================================
#    3. INSTALAR OBSERVIUM COMMUNITY
# ==================================================
echo "Descargando Observium Community en $INSTALL_DIR..."
if [ ! -d "$INSTALL_DIR" ]; then
    git clone https://github.com/observium/observium-community.git "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

echo "Copiando y editando archivo de configuración..."
cp config.php.default config.php
sed -i "s|\$config\['db_host'\] = 'localhost';|\$config['db_host'] = 'localhost';|g" config.php
sed -i "s|\$config\['db_user'\] = 'observium';|\$config['db_user'] = '$OBS_DB_USER';|g" config.php
sed -i "s|\$config\['db_pass'\] = 'observium';|\$config['db_pass'] = '$OBS_DB_PASS';|g" config.php
sed -i "s|\$config\['db_name'\] = 'observium';|\$config['db_name'] = '$OBS_DB_NAME';|g" config.php

# Ajustar timezone PHP para Observium
echo "\$config['php_timezone'] = '$PHP_TIMEZONE';" >> config.php

echo "Inicializando la base de datos de Observium..."
./discovery.php -u
./discovery.php -h all
./validate.php || true  # Si hay warnings, no queremos abortar el script

echo "Creando usuario administrador en Observium..."
# Nivel 10 = admin
./adduser.php $OBS_ADMIN_USER $OBS_ADMIN_PASS 10

# ==================================================
#    4. CONFIGURAR APACHE
# ==================================================
echo "Configurando VirtualHost en Apache..."
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

# Ajustes de permisos
chown -R apache:apache "$INSTALL_DIR"

# SELinux (si está habilitado)
if sestatus | grep -q "enforcing"; then
  echo "Ajustando contexto SELinux..."
  dnf -y install policycoreutils-python-utils || true
  semanage fcontext -a -t httpd_sys_rw_content_t "$INSTALL_DIR(/.*)?"
  restorecon -RF "$INSTALL_DIR"
fi

# Reiniciar Apache
systemctl restart httpd

# ==================================================
#    5. MENSAJE FINAL
# ==================================================
echo "----------------------------------------"
echo "¡Instalación de Observium completada!"
echo "URL de acceso:  http://$SERVER_NAME/"
echo "Usuario admin:  $OBS_ADMIN_USER"
echo "Contraseña:     $OBS_ADMIN_PASS"
echo "Base de datos:  $OBS_DB_NAME  (user: $OBS_DB_USER)"
echo "----------------------------------------"
echo "Si tu SELinux está activo, revisa que no bloquee puertos."
echo "¡Listo! Disfruta de tu Observium Community Edition."
