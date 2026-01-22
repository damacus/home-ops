FROM ruby:3.4-alpine

# Install dependencies
RUN apk add --no-cache \
    build-base \
    curl \
    bash \
    git

# Install kubectl (auto-detect architecture)
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
    x86_64) KUBECTL_ARCH="amd64" ;; \
    aarch64) KUBECTL_ARCH="arm64" ;; \
    *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${KUBECTL_ARCH}/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Set working directory
WORKDIR /app

# Copy Gemfile first for layer caching
COPY Gemfile Gemfile.lock* ./

# Install gems
RUN bundle config set --local without 'development test' && \
    bundle install --jobs 4 --retry 3

# Copy application code
COPY . .

# Make binary executable
RUN chmod +x bin/zitadel-tui

# Set entrypoint
ENTRYPOINT ["./bin/zitadel-tui"]
