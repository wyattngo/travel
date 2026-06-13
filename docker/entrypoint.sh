#!/bin/sh
# Container start: make storage writable, cache config/views, wait for DB,
# run migrations, seed once if empty, then hand off to supervisor (nginx+fpm).
set -e
cd /var/www/html

# Make runtime dirs writable (also covers mounted volumes)
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true

# Cache config & views (env is injected by compose env_file)
php artisan config:clear >/dev/null 2>&1 || true
php artisan config:cache
php artisan view:cache
# NOTE: route:cache is intentionally skipped — routes/api.php uses closure routes.

# Wait for the database, then migrate (retry loop)
echo "→ Running migrations (waiting for DB if needed)…"
i=0
until php artisan migrate --force; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
        echo "✗ Database still unavailable after 30 attempts — aborting."
        exit 1
    fi
    echo "  DB not ready, retry $i/30 in 3s…"
    sleep 3
done

# Seed once, only when the catalog is empty (safe across restarts)
if [ "${DB_SEED:-true}" = "true" ]; then
    COUNT=$(php artisan tinker --execute="try{echo \DB::table('destinations')->count();}catch(\Throwable \$e){echo 0;}" 2>/dev/null | tr -dc '0-9')
    if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then
        echo "→ Seeding database…"
        php artisan db:seed --force || true
    else
        echo "→ Data already present (destinations=$COUNT) — skip seeding."
    fi
fi

php artisan storage:link 2>/dev/null || true

echo "→ Boot complete. Starting nginx + php-fpm."
exec "$@"
