FROM ruby:3.4-bullseye

# Install dependencies
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends \
    build-essential \
    git \
    libevent-dev \
    libmemcached-tools \
    curl \
    procps \
    wget \
    bash \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# Setup non-root user with sudo access
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && apt-get update \
    && apt-get install -y sudo \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

RUN sudo chown -R $USERNAME:$USERNAME /usr/local/bundle

# Install utilities
RUN gem install bundler

WORKDIR /workspace

# Switch to non-root user
USER $USERNAME
