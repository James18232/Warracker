# syntax=docker/dockerfile:1.19.0@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6

########################################
# BUILDER STAGE
########################################
FROM python:3.13-slim-trixie@sha256:079601253d5d25ae095110937ea8cfd7403917b53b077870bccd8b026dc7c42f AS builder

# Build-time package versions
ARG BUILD_ESSENTIAL_VERSION=12.12
ARG LIBPQ_DEV_VERSION=17.6-0+deb13u1
ARG LIBCURL4_OPENSSL_DEV_VERSION=8.14.1-2
ARG LIBSSL_DEV_VERSION=3.5.1-1+deb13u1
ARG PKG_CONFIG_VERSION=1.8.1-4

# Install build tools (only in builder stage)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential=${BUILD_ESSENTIAL_VERSION} \
        libpq-dev=${LIBPQ_DEV_VERSION} \
        libcurl4-openssl-dev=${LIBCURL4_OPENSSL_DEV_VERSION} \
        libssl-dev=${LIBSSL_DEV_VERSION} \
        pkg-config=${PKG_CONFIG_VERSION} && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Upgrade pip
RUN pip install --no-cache-dir --upgrade pip

# Install Python dependencies
COPY backend/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt


########################################
# RUNTIME STAGE
########################################
FROM python:3.13-slim-trixie@sha256:079601253d5d25ae095110937ea8cfd7403917b53b077870bccd8b026dc7c42f AS runtime

# Metadata for final image
LABEL org.opencontainers.image.source="https://github.com/sassanix/Warracker"
LABEL org.opencontainers.image.description="Warracker - Warranty Tracker"

# Install runtime dependencies (version-agnostic)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        nginx \
        supervisor \
        postgresql-client \
        gettext-base \
        curl \
        ca-certificates \
        libpq5 \
        libcurl4 \
        libssl3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Create non-root user
RUN groupadd -r -g 999 warracker && \
    useradd -r -g warracker -u 999 -d /home/warracker -m -s /bin/bash warracker

# Copy Python dependencies from builder
COPY --from=builder /usr/local /usr/local

# Configure directories
RUN mkdir -p /app /var/www/html /var/log/supervisor /run/nginx && \
    chown -R warracker:warracker /app /var/www/html /var/log/supervisor /run/nginx /home/warracker && \
    chown -R warracker:warracker /var/log/nginx

# Set working directory
WORKDIR /app

# Copy configuration and static files
COPY --chown=warracker:warracker nginx.conf /etc/nginx/conf.d/default.conf.template
COPY --chown=warracker:warracker babel.cfg ./

# Copy migration scripts and utilities
COPY --chown=warracker:warracker backend/fix_permissions.py backend/fix_permissions.sql ./
COPY --chown=warracker:warracker backend/migrations/ ./migrations/

# Copy localization files
COPY --chown=warracker:warracker locales/ ./locales/
COPY --chown=warracker:warracker locales/ /var/www/html/locales/

# Copy frontend and backend
COPY --chown=warracker:warracker frontend/ /var/www/html/
COPY --chown=warracker:warracker backend/ ./backend/
COPY --chown=warracker:warracker backend/app.py backend/gunicorn_config.py ./

# Copy Docker scripts
COPY --chown=root:root Docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY --chown=warracker:warracker Docker/entrypoint.sh /app/entrypoint.sh
COPY --chown=root:root Docker/nginx-wrapper.sh /app/nginx-wrapper.sh

# Make scripts executable
RUN chmod +x /app/entrypoint.sh /app/nginx-wrapper.sh

# Environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    NGINX_MAX_BODY_SIZE_VALUE=32M

# Remove default nginx site
RUN rm -f /etc/nginx/sites-enabled/default

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost/api/health 2>/dev/null || curl -f http://localhost/ || exit 1

# Expose port
EXPOSE 80

# Entry point
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
