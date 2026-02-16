#!/bin/bash
set -e

# This script runs during PostgreSQL first-time initialization (docker-entrypoint-initdb.d).
# It creates a limited-privilege application user and database separate from the admin superuser.
# Environment variables are passed from the postgres service in docker-compose.yml.

APP_DB="${POSTGRES_APP_DB:-n8n}"
APP_USER="${POSTGRES_APP_USER:-n8n}"
APP_PASSWORD="${POSTGRES_APP_PASSWORD:-}"

# If no app password is set, skip user separation
if [ -z "$APP_PASSWORD" ]; then
    echo "init-postgres: POSTGRES_APP_PASSWORD not set, skipping app user creation"
    exit 0
fi

echo "init-postgres: Creating application database '$APP_DB' and user '$APP_USER'..."

# Create application user if it doesn't exist
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$APP_USER') THEN
            CREATE ROLE "$APP_USER" WITH LOGIN PASSWORD '$APP_PASSWORD';
        END IF;
    END
    \$\$;
EOSQL

# Create application database if it doesn't exist
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT 'CREATE DATABASE "$APP_DB" OWNER "$APP_USER"'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$APP_DB')\gexec
EOSQL

# Grant privileges
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$APP_DB" <<-EOSQL
    GRANT ALL PRIVILEGES ON DATABASE "$APP_DB" TO "$APP_USER";
    GRANT ALL PRIVILEGES ON SCHEMA public TO "$APP_USER";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "$APP_USER";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "$APP_USER";
EOSQL

# Enable pgvector extension in the app database
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$APP_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
EOSQL

echo "init-postgres: Application database '$APP_DB' and user '$APP_USER' created successfully."
