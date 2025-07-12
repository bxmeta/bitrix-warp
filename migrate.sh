#!/bin/bash

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Переменные для подключения к серверу B
IP=""
LOGIN=""
PASSWORD=""
REMOTE_PATH=""
EXCLUDE=""

# Переменные для базы данных на сервере A
DB_HOST=""
DB_NAME=""
DB_USER=""
DB_PASS=""

# Рабочие переменные
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ARCHIVE_NAME="bitrix_migration_${TIMESTAMP}.tar.gz"
DB_DUMP_NAME="database_${TIMESTAMP}.sql"

# Функция для вывода прогресса
progress() {
    local percent="$1"
    local message="$2"
    echo -e "${BLUE}[${percent}%]${NC} ${message}"
}

# Функция для вывода ошибки и выхода
error_exit() {
    echo -e "${RED}ОШИБКА:${NC} $1" >&2
    cleanup
    exit 1
}

# Функция для вывода успеха
success() {
    echo -e "${GREEN}$1${NC}"
}

# Функция для вывода предупреждения
warning() {
    echo -e "${YELLOW}ВНИМАНИЕ:${NC} $1"
}

# Функция очистки временных файлов
cleanup() {
    if [[ -n "${REMOTE_TEMP_DIR:-}" ]]; then
        echo "Очистка временных файлов на удаленном сервере..."
        sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$LOGIN@$IP" \
            "rm -rf '$REMOTE_TEMP_DIR'" 2>/dev/null || true
    fi
    
    if [[ -f "$ARCHIVE_NAME" ]]; then
        rm -f "$ARCHIVE_NAME"
    fi
    
    if [[ -f "$DB_DUMP_NAME" ]]; then
        rm -f "$DB_DUMP_NAME"
    fi
}

# Обработчик сигналов для очистки
trap cleanup EXIT

# Функция для загрузки переменных из .env файла
load_env_file() {
    if [[ -f "$ENV_FILE" ]]; then
        while IFS='=' read -r key value; do
            # Пропускаем комментарии и пустые строки
            [[ $key =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            # Удаляем кавычки из значения
            value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
            
            case "$key" in
                IP) [[ -z "$IP" ]] && IP="$value" ;;
                LOGIN) [[ -z "$LOGIN" ]] && LOGIN="$value" ;;
                PASSWORD) [[ -z "$PASSWORD" ]] && PASSWORD="$value" ;;
                REMOTE_PATH) [[ -z "$REMOTE_PATH" ]] && REMOTE_PATH="$value" ;;
                EXCLUDE) [[ -z "$EXCLUDE" ]] && EXCLUDE="$value" ;;
                DB_HOST) [[ -z "$DB_HOST" ]] && DB_HOST="$value" ;;
                DB_NAME) [[ -z "$DB_NAME" ]] && DB_NAME="$value" ;;
                DB_USER) [[ -z "$DB_USER" ]] && DB_USER="$value" ;;
                DB_PASS) [[ -z "$DB_PASS" ]] && DB_PASS="$value" ;;
            esac
        done < "$ENV_FILE"
    fi
}

# Функция для парсинга аргументов командной строки
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ip=*)
                IP="${1#*=}"
                shift
                ;;
            --login=*)
                LOGIN="${1#*=}"
                shift
                ;;
            --password=*)
                PASSWORD="${1#*=}"
                shift
                ;;
            --remote_path=*)
                REMOTE_PATH="${1#*=}"
                shift
                ;;
            --exclude=*)
                EXCLUDE="${1#*=}"
                shift
                ;;
            --db_host=*)
                DB_HOST="${1#*=}"
                shift
                ;;
            --db_name=*)
                DB_NAME="${1#*=}"
                shift
                ;;
            --db_user=*)
                DB_USER="${1#*=}"
                shift
                ;;
            --db_pass=*)
                DB_PASS="${1#*=}"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error_exit "Неизвестный параметр: $1"
                ;;
        esac
    done
}

# Функция для отображения справки
show_help() {
    cat << EOF
Скрипт миграции сайта Bitrix

Использование: $0 [ОПЦИИ]

Опции:
  --ip=IP                 IP адрес исходного сервера (B)
  --login=LOGIN          Логин для подключения к серверу B
  --password=PASSWORD    Пароль для подключения к серверу B
  --remote_path=PATH     Путь к сайту на сервере B
  --exclude=DIRS         Исключаемые директории (через запятую)
  --db_host=HOST         Хост базы данных на сервере A
  --db_name=NAME         Имя новой базы данных
  --db_user=USER         Пользователь базы данных
  --db_pass=PASS         Пароль базы данных
  -h, --help             Показать эту справку

Переменные также могут быть заданы в файле .env
EOF
}

# Функция для интерактивного ввода недостающих параметров
interactive_input() {
    [[ -z "$IP" ]] && read -p "Введите IP адрес сервера B: " IP
    [[ -z "$LOGIN" ]] && read -p "Введите логин для сервера B: " LOGIN
    [[ -z "$PASSWORD" ]] && read -s -p "Введите пароль для сервера B: " PASSWORD && echo
    [[ -z "$REMOTE_PATH" ]] && read -p "Введите путь к сайту на сервере B: " REMOTE_PATH
    [[ -z "$EXCLUDE" ]] && read -p "Введите исключаемые директории (через запятую, по умолчанию: upload,bitrix/cache,log): " EXCLUDE
    [[ -z "$EXCLUDE" ]] && EXCLUDE="upload,bitrix/cache,log"
    [[ -z "$DB_HOST" ]] && read -p "Введите хост БД на сервере A (по умолчанию: localhost): " DB_HOST
    [[ -z "$DB_HOST" ]] && DB_HOST="localhost"
    [[ -z "$DB_NAME" ]] && read -p "Введите имя новой базы данных: " DB_NAME
    [[ -z "$DB_USER" ]] && read -p "Введите пользователя БД: " DB_USER
    [[ -z "$DB_PASS" ]] && read -s -p "Введите пароль БД: " DB_PASS && echo
}

# Функция проверки зависимостей
check_dependencies() {
    local deps=("sshpass" "scp" "tar" "mysqldump" "mysql")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error_exit "Требуется установить: $dep"
        fi
    done
}

# Функция для проверки SSH подключения
test_ssh_connection() {
    progress 5 "Проверка подключения к серверу B..."
    
    if ! sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$LOGIN@$IP" "echo 'SSH подключение успешно'" &>/dev/null; then
        error_exit "Не удается подключиться к серверу $IP"
    fi
    
    success "SSH подключение установлено"
}

# Функция для извлечения параметров базы данных из .settings.php
extract_db_settings() {
    progress 15 "Извлечение параметров БД из .settings.php..."
    
    local settings_file="$REMOTE_PATH/bitrix/.settings.php"
    
    # Проверяем существование файла настроек
    if ! sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$LOGIN@$IP" "test -f '$settings_file'"; then
        error_exit "Файл .settings.php не найден по пути: $settings_file"
    fi
    
    # Извлекаем настройки базы данных
    local db_settings
    db_settings=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$LOGIN@$IP" "
        php -r \"
        \\\$settings = include '$settings_file';
        if (isset(\\\$settings['connections']['default']['host'])) {
            echo \\\$settings['connections']['default']['host'] . '|';
            echo \\\$settings['connections']['default']['database'] . '|';
            echo \\\$settings['connections']['default']['login'] . '|';
            echo \\\$settings['connections']['default']['password'];
        } else {
            exit(1);
        }
        \"
    ")
    
    if [[ $? -ne 0 ]] || [[ -z "$db_settings" ]]; then
        error_exit "Не удается извлечь параметры БД из .settings.php"
    fi
    
    IFS='|' read -r REMOTE_DB_HOST REMOTE_DB_NAME REMOTE_DB_USER REMOTE_DB_PASS <<< "$db_settings"
    
    success "Параметры БД извлечены: $REMOTE_DB_NAME@$REMOTE_DB_HOST"
}

# Функция для создания дампа базы данных
create_database_dump() {
    progress 25 "Создание дампа базы данных..."
    
    # Создаем временную директорию на удаленном сервере
    REMOTE_TEMP_DIR="/tmp/bitrix_migration_$$"
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$LOGIN@$IP" "mkdir -p '$REMOTE_TEMP_DIR'"
    
    local remote_dump_path="$REMOTE_TEMP_DIR/$DB_DUMP_NAME"
    
    # Создаем дамп базы данных
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$LOGIN@$IP" "
        mysqldump -h'$REMOTE_DB_HOST' -u'$REMOTE_DB_USER' -p'$REMOTE_DB_PASS' \
        --single-transaction --routines --triggers '$REMOTE_DB_NAME' > '$remote_dump_path'
    "
    
    if [[ $? -ne 0 ]]; then
        error_exit "Ошибка создания дампа базы данных"
    fi
    
    success "Дамп базы данных создан"
}

# Функция для создания архива сайта
create_site_archive() {
    progress 35 "Архивация сайта..."
    
    # Формируем список исключений для tar
    local exclude_params=""
    if [[ -n "$EXCLUDE" ]]; then
        IFS=',' read -ra EXCLUDE_ARRAY <<< "$EXCLUDE"
        for dir in "${EXCLUDE_ARRAY[@]}"; do
            exclude_params="$exclude_params --exclude='${dir// /}'"
        done
    fi
    
    # Создаем архив на удаленном сервере
    local remote_archive_path="$REMOTE_TEMP_DIR/$ARCHIVE_NAME"
    
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$LOGIN@$IP" "
        cd '$REMOTE_PATH' && \
        tar -czf '$remote_archive_path' $exclude_params \
        --exclude='$REMOTE_TEMP_DIR' \
        -C '$REMOTE_TEMP_DIR' '$DB_DUMP_NAME' \
        -C '$REMOTE_PATH' .
    "
    
    if [[ $? -ne 0 ]]; then
        error_exit "Ошибка создания архива"
    fi
    
    success "Архив сайта создан"
}

# Функция для передачи архива
transfer_archive() {
    progress 50 "Передача архива на сервер A..."
    
    local remote_archive_path="$REMOTE_TEMP_DIR/$ARCHIVE_NAME"
    
    scp -o StrictHostKeyChecking=no "sshpass -p '$PASSWORD' ssh $LOGIN@$IP 'cat $remote_archive_path'" > "$ARCHIVE_NAME"
    
    if [[ $? -ne 0 ]] || [[ ! -f "$ARCHIVE_NAME" ]]; then
        error_exit "Ошибка передачи архива"
    fi
    
    success "Архив передан на сервер A"
}

# Функция для распаковки архива
extract_archive() {
    progress 65 "Распаковка архива..."
    
    if ! tar -xzf "$ARCHIVE_NAME"; then
        error_exit "Ошибка распаковки архива"
    fi
    
    success "Архив распакован"
}

# Функция для создания и настройки базы данных
setup_database() {
    progress 75 "Создание и настройка базы данных..."
    
    # Создаем базу данных
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    
    if [[ $? -ne 0 ]]; then
        error_exit "Ошибка создания базы данных"
    fi
    
    # Импортируем дамп
    if [[ -f "$DB_DUMP_NAME" ]]; then
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$DB_DUMP_NAME"
        
        if [[ $? -ne 0 ]]; then
            error_exit "Ошибка импорта базы данных"
        fi
    else
        error_exit "Файл дампа базы данных не найден"
    fi
    
    success "База данных создана и данные импортированы"
}

# Функция для обновления настроек Bitrix
update_bitrix_settings() {
    progress 85 "Обновление настроек Bitrix..."
    
    local settings_file="bitrix/.settings.php"
    
    if [[ ! -f "$settings_file" ]]; then
        error_exit "Файл .settings.php не найден в распакованных файлах"
    fi
    
    # Создаем резервную копию
    cp "$settings_file" "${settings_file}.backup"
    
    # Обновляем настройки базы данных
    php -r "
    \$settings = include '$settings_file';
    \$settings['connections']['default']['host'] = '$DB_HOST';
    \$settings['connections']['default']['database'] = '$DB_NAME';
    \$settings['connections']['default']['login'] = '$DB_USER';
    \$settings['connections']['default']['password'] = '$DB_PASS';
    
    file_put_contents('$settings_file', '<?php' . PHP_EOL . 'return ' . var_export(\$settings, true) . ';');
    "
    
    if [[ $? -ne 0 ]]; then
        warning "Не удается автоматически обновить .settings.php. Обновите вручную:"
        echo "  host: $DB_HOST"
        echo "  database: $DB_NAME"
        echo "  login: $DB_USER"
        echo "  password: $DB_PASS"
    else
        success "Настройки Bitrix обновлены"
    fi
}

# Функция финальной очистки
final_cleanup() {
    progress 95 "Финальная очистка..."
    
    # Удаляем дамп базы данных
    [[ -f "$DB_DUMP_NAME" ]] && rm -f "$DB_DUMP_NAME"
    
    # Удаляем архив
    [[ -f "$ARCHIVE_NAME" ]] && rm -f "$ARCHIVE_NAME"
    
    success "Временные файлы удалены"
}

# Основная функция
main() {
    echo "=== Скрипт миграции сайта Bitrix ==="
    echo
    
    # Проверяем зависимости
    check_dependencies
    
    # Загружаем переменные из .env файла
    load_env_file
    
    # Парсим аргументы командной строки
    parse_arguments "$@"
    
    # Интерактивный ввод недостающих параметров
    interactive_input
    
    # Проверяем обязательные параметры
    if [[ -z "$IP" || -z "$LOGIN" || -z "$PASSWORD" || -z "$REMOTE_PATH" || -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]]; then
        error_exit "Не все обязательные параметры заданы"
    fi
    
    echo
    echo "Параметры миграции:"
    echo "  Исходный сервер: $LOGIN@$IP:$REMOTE_PATH"
    echo "  Целевая БД: $DB_USER@$DB_HOST/$DB_NAME"
    echo "  Исключения: $EXCLUDE"
    echo
    
    read -p "Продолжить миграцию? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Миграция отменена"
        exit 0
    fi
    
    echo
    echo "Начинаем миграцию..."
    
    # Выполняем миграцию
    test_ssh_connection
    extract_db_settings
    create_database_dump
    create_site_archive
    transfer_archive
    extract_archive
    setup_database
    update_bitrix_settings
    final_cleanup
    
    progress 100 "Готово!"
    echo
    success "✅ Миграция сайта Bitrix завершена успешно!"
    echo
    echo "Что нужно сделать далее:"
    echo "1. Проверьте работу сайта"
    echo "2. Настройте веб-сервер (Apache/Nginx)"
    echo "3. Проверьте права доступа к файлам"
    echo "4. Очистите кэш Bitrix"
    echo
}

# Запуск основной функции
main "$@"