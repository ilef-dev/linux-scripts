#!/bin/bash
# Основная папка скрипта
SETUP_DIR="setup"
sudo mkdir -p $SETUP_DIR

# Переменные
WIREGUARD_SETUP_DIR="$SETUP_DIR/wireguard"
DOCKER_SETUP_DIR="$SETUP_DIR/docker"


LOGFILE="$SETUP_DIR/setup.log"
exec > >(tee -a $LOGFILE) 2>&1

# Проверка прав суперпользователя
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть выполнен с правами суперпользователя." >&2
    exit 1
fi
# Функция для запроса обновления пакетов
prompt_update() {
    read -p "Рекомендуем использовать этот скрипт на чистой Ubuntu 24.04 и обновить пакеты перед запуском. Хотите продолжить? (y/n): " response
    case "$response" in
        [yY][eE][sS]|[yY])
            ;;
        [nN][oO]|[nN])
            exit 1
            ;;
        *)
            echo "Неправильный ввод. Пожалуйста, введите 'yes' или 'no'."
            prompt_update
            ;;
    esac
}
# Проверяем обновление пакетов перед продолжением
prompt_update



# Заполняем глобальные переменные
read -p "Введите название wireguard конфигурации: " WG_CONFIG_NAME
read -p "Введите выделенный для вашего сервера внешний ip: " YOUR_SERVER_IP
read -p "Введите port для сервера wireguard: " SERVER_PORT
read -p "Введите путь к папке данных gitlab: " GITLAB_DIR
read -p "Введите port к http gitlab: " GITLAB_HTTP_PORT
read -p "Введите port к ssh gitlab: " GITLAB_SSH_PORT
read -p "Введите путь к папке данных nextcloud: " NEXTCLOUD_DIR
read -p "Введите port для сервера nextcloud: " NEXTCLOUD_PORT


# Установка часового пояса
if ! sudo timedatectl set-timezone Europe/Moscow; then
    echo "Ошибка установки часового пояса" >&2
    exit 1
fi
echo "Начало установки: $(date)"


#-----wireguard-----#
# Функция для генерации ключей
generate_keys() {
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
    echo "$private_key $public_key"
}

# Установка WireGuard
echo "Устанавливаем WireGuard..."
sudo apt install -y wireguard

# Генерация ключей
echo "Генерируем ключи..."
server_keys=($(generate_keys))
client_keys=($(generate_keys))

server_private_key=${server_keys[0]}
server_public_key=${server_keys[1]}
client_private_key=${client_keys[0]}
client_public_key=${client_keys[1]}

# Создание директорий
sudo mkdir -p $WIREGUARD_SETUP_DIR
sudo mkdir -p $WIREGUARD_SETUP_DIR/keys

# Сохранение ключей
echo "Сохраняем ключи..."
sudo tee $WIREGUARD_SETUP_DIR/keys/server_private.key <<< "$server_private_key"
sudo tee $WIREGUARD_SETUP_DIR/keys/server_public.key <<< "$server_public_key"
sudo tee $WIREGUARD_SETUP_DIR/keys/client_private.key <<< "$client_private_key"
sudo tee $WIREGUARD_SETUP_DIR/keys/client_public.key <<< "$client_public_key"

# Настройка $WG_CONFIG_NAME.conf
echo "Создаем конфигурацию $WG_CONFIG_NAME.conf для сервера"
sudo tee /etc/wireguard/$WG_CONFIG_NAME.conf <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = $SERVER_PORT
PrivateKey = $server_private_key

[Peer]
PublicKey = $client_public_key
AllowedIPs = 10.0.0.2/32
EOF

# Настройка $WG_CONFIG_NAME.conf
echo "Создаем конфигурацию $WG_CONFIG_NAME.conf для клиента"
tee $WIREGUARD_SETUP_DIR/$WG_CONFIG_NAME.conf <<EOF
[Interface]
PrivateKey = $client_private_key
Address = 10.0.0.2/32

[Peer]
PublicKey = $server_public_key
Endpoint = $YOUR_SERVER_IP:$SERVER_PORT
AllowedIPs = 10.0.0.1/32
EOF

# Запуск и включение WireGuard
echo "Запускаем и включаем WireGuard..."
sudo systemctl start wg-quick@$WG_CONFIG_NAME
sudo systemctl enable wg-quick@$WG_CONFIG_NAME

echo "Установка и настройка WireGuard завершены."
echo "Конфигурация клиента сохранена в $WIREGUARD_SETUP_DIR/$WG_CONFIG_NAME.conf"



#-----docker-----#
echo "Устанавливаем Docker..."

# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo mkdir -p $DOCKER_SETUP_DIR

echo "Установка и настройка Docker завершены."



#-----gitlab-----#
echo "Устанавливаем Gitlab..."

tee $DOCKER_SETUP_DIR/gitlab.yml <<EOF
version: '3.6'
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab
    restart: always
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://10.0.0.1:$GITLAB_HTTP_PORT';
        gitlab_rails['gitlab_shell_ssh_port'] = $GITLAB_SSH_PORT
    ports:
      - '$GITLAB_HTTP_PORT:$GITLAB_HTTP_PORT'
      - '$GITLAB_SSH_PORT:22'
    volumes:
      - '$GITLAB_DIR/config:/etc/gitlab'
      - '$GITLAB_DIR/logs:/var/log/gitlab'
      - '$GITLAB_DIR/data:/var/opt/gitlab'
    shm_size: '256m'
EOF

sudo docker compose -f $DOCKER_SETUP_DIR/gitlab.yml up -d
echo "Установка и настройка Gitlab завершены."



#-----nextcloud-----#
echo "Устанавливаем Nextcloud..."

tee $DOCKER_SETUP_DIR/nextcloud.yml <<EOF
version: '3.9'

services:
  db:
    image: postgres:latest
    container_name: nextcloud_db
    restart: unless-stopped
    volumes:
      - $NEXTCLOUD_DIR/db:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=nextcloud
      - POSTGRES_USER=nextcloud
      - POSTGRES_PASSWORD=nextcloud
    networks:
      - nextcloud_network

  app:
    image: nextcloud:latest
    container_name: nextcloud_app
    restart: unless-stopped
    ports:
      - $NEXTCLOUD_PORT:80
    volumes:
      - $NEXTCLOUD_DIR/data:/var/www/html
    environment:
      - POSTGRES_HOST=db
      - POSTGRES_DB=nextcloud
      - POSTGRES_USER=nextcloud
      - POSTGRES_PASSWORD=nextcloud
      - NEXTCLOUD_TRUSTED_DOMAINS=10.0.0.1
      - REDIS_HOST=redis
      - PHP_MEMORY_LIMIT=4G
      - NEXTCLOUD_ADMIN_USER=admin
      - NEXTCLOUD_ADMIN_PASSWORD=admin
    depends_on:
      - db
      - redis
    networks:
      - nextcloud_network

  redis:
    image: redis:latest
    container_name: nextcloud_redis
    restart: unless-stopped
    volumes:
      - $NEXTCLOUD_DIR/redis:/data
    networks:
      - nextcloud_network

networks:
  nextcloud_network:
    driver: bridge

EOF

sudo docker compose -f $DOCKER_SETUP_DIR/nextcloud.yml up -d
echo "Установка и настройка Nextcloud завершены."



#-----Завершение-----#
echo "Для получения пароля администратора gitlab введите:"
echo "sudo docker exec -it gitlab grep 'Password:' /etc/gitlab/initial_root_password"