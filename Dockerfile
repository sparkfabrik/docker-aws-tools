# AWS CLI v2
ARG AWS_CLI_VERSION=2.15.0
ARG ALPINE_VERSION=3.18
# To fetch the right alpine version use:
# docker run --rm --entrypoint ash eu.gcr.io/google.com/cloudsdktool/google-cloud-cli:${GOOGLE_CLOUD_CLI_IMAGE_TAG} -c 'cat /etc/issue'
# Check the available version here: https://github.com/sparkfabrik/docker-alpine-aws-cli/pkgs/container/docker-alpine-aws-cli

# Use the same version of the base image in different stages
ARG GOOGLE_CLOUD_CLI_IMAGE_TAG

FROM ghcr.io/sparkfabrik/docker-alpine-aws-cli:${AWS_CLI_VERSION}-alpine${ALPINE_VERSION} as awscli

# Building and downloading all the tools in a single stage
FROM eu.gcr.io/google.com/cloudsdktool/google-cloud-cli:${GOOGLE_CLOUD_CLI_IMAGE_TAG} as build

# Build target arch passed by BuildKit
ARG TARGETARCH

# Install components for the building stage.
RUN apk --no-cache add autoconf automake build-base curl gzip libtool make openssl unzip

# Download helm
# https://github.com/helm/helm/releases
ENV HELM_VERSION 3.13.2
RUN curl -o /tmp/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz -L0 "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
  && tar -zxvf /tmp/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz -C /tmp \
  && mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm

# Download stern
# https://github.com/stern/stern/releases
ENV STERN_VERSION 1.27.0
RUN curl -o /tmp/stern_${STERN_VERSION}_linux_${TARGETARCH}.tar.gz -LO "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_${TARGETARCH}.tar.gz" \
  && tar -zxvf /tmp/stern_${STERN_VERSION}_linux_${TARGETARCH}.tar.gz -C /tmp \
  && mv /tmp/stern /usr/local/bin/stern

# Download jq
# https://github.com/jqlang/jq/releases
ENV JQ_VERSION 1.7
RUN curl -o /tmp/jq-${JQ_VERSION}.tar.gz -L0 "https://github.com/stedolan/jq/archive/refs/tags/jq-${JQ_VERSION}.tar.gz" \
  && tar -zxvf /tmp/jq-${JQ_VERSION}.tar.gz -C /tmp

# https://github.com/kkos/oniguruma/tree/v6.9.9
ENV ONIGURUMA_VERSION 6.9.9
RUN curl -o /tmp/oniguruma-${ONIGURUMA_VERSION}.tar.gz -L0 "https://github.com/kkos/oniguruma/archive/refs/tags/v${ONIGURUMA_VERSION}.tar.gz" \
  && tar -zxvf /tmp/oniguruma-${ONIGURUMA_VERSION}.tar.gz -C /tmp

# Compile JQ
RUN cd /tmp/jq-jq-${JQ_VERSION} \
  && rmdir modules/oniguruma \
  && mv /tmp/oniguruma-${ONIGURUMA_VERSION} /tmp/jq-jq-${JQ_VERSION}/modules/oniguruma \
  && autoreconf -fi \
  && ./configure --with-oniguruma=builtin --disable-maintainer-mode \
  && make LDFLAGS=-all-static -j4 \
  && mv jq /usr/local/bin/jq

# Use the same version of the base image in different stages
ARG GOOGLE_CLOUD_CLI_IMAGE_TAG

# Create the final image
FROM eu.gcr.io/google.com/cloudsdktool/google-cloud-cli:${GOOGLE_CLOUD_CLI_IMAGE_TAG}
LABEL org.opencontainers.image.source=https://github.com/sparkfabrik/docker-cloud-tools

# Build target arch passed by BuildKit
ARG TARGETARCH

# Add additional components to gcloud SDK.
RUN gcloud components install app-engine-java beta gke-gcloud-auth-plugin

# Use the gke-auth-plugin to authenticate to the GKE cluster.
# Install gke-gcloud-auth-plugin (https://cloud.google.com/blog/products/containers-kubernetes/kubectl-auth-changes-in-gke)
ENV USE_GKE_GCLOUD_AUTH_PLUGIN true

# Remove unnecessary components.
RUN rm -f /usr/local/libexec/docker/cli-plugins/docker-buildx

# Install additional components.
RUN apk --no-cache add bat curl less make vim \
  bash-completion grep groff gettext  \
  openssl ncurses unzip yq

# Create utility folder
RUN mkdir -p /utility

# Install AWS CLI v2 using the binary builded in the awscli stage
COPY --from=awscli /usr/local/aws-cli/ /usr/local/aws-cli/
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws \
  && ln -s /usr/local/aws-cli/v2/current/bin/aws_completer /usr/local/bin/aws_completer

# Download kubectl
RUN curl -o /usr/local/bin/kubectl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH}/kubectl" \
  && chmod +x /usr/local/bin/kubectl

# Download kubectx and kubens utilities
# https://github.com/ahmetb/kubectx
ENV KUBECTX_VERSION 0.9.5
RUN curl -o /utility/kubens -sLO "https://github.com/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/kubens" \
  && curl -o /utility/kubectx -sLO "https://github.com/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/kubectx" \
  && chmod +x /utility/kubens /utility/kubectx \
  && curl -o /utility/kubens.autocomple.sh -sLO "https://raw.githubusercontent.com/ahmetb/kubectx/v${KUBECTX_VERSION}/completion/kubens.bash" \
  && curl -o /etc/profile.d/kubectx.sh -sLO "https://raw.githubusercontent.com/ahmetb/kubectx/v${KUBECTX_VERSION}/completion/kubectx.bash" \
  && chmod +x /etc/profile.d/kubectx.sh /utility/kubens.autocomple.sh

# Copy helm from previous stage
COPY --from=build /usr/local/bin/helm /usr/local/bin/helm
RUN chmod +x /usr/local/bin/helm

# Copy stern from previous stage
COPY --from=build /usr/local/bin/stern /usr/local/bin/stern
RUN chmod +x /usr/local/bin/stern

# Copy compiled jq from previous stage
COPY --from=build /usr/local/bin/jq /usr/local/bin/jq
RUN chmod +x /usr/local/bin/jq

# Overwrite kubens with custom kubens script (we don't have namespace list permission)
COPY scripts/kubens /utility/kubens.patched
RUN chmod +x /utility/kubens.patched
RUN ln -s /utility/kubens.patched /usr/local/bin/kubens

# Create userless home, it will be used only for cache
ENV HOME /cloud-tools-cli
RUN mkdir /cloud-tools-cli \
  && chmod 777 /cloud-tools-cli

# Save history
ENV HISTFILE=/cloud-tools-cli/dotfiles/.bash_history
RUN mkdir -p /cloud-tools-cli/dotfiles

# Prompter function to build the bash prompt with additional information
ENV PROMPT_COMMAND=prompter
COPY scripts/prompter.sh /etc/profile.d/prompter.sh
RUN chmod +x /etc/profile.d/prompter.sh

# Final settings
RUN touch /etc/profile.d/tools-completion.sh \
  && chmod +x /etc/profile.d/tools-completion.sh \
  && echo "source <(kubectl completion bash)" >> /etc/profile.d/tools-completion.sh \
  && echo "alias k=\"kubectl\"" >> /etc/profile.d/tools-completion.sh \
  && echo "complete -o default -F __start_kubectl k" >> /etc/profile.d/tools-completion.sh \
  && echo "source <(helm completion bash)" >> /etc/profile.d/tools-completion.sh \
  && echo "source <(stern --completion bash)" >> /etc/profile.d/tools-completion.sh \
  && echo "source /google-cloud-sdk/path.bash.inc" >> /etc/profile.d/tools-completion.sh \
  && echo "complete -C '/usr/local/bin/aws_completer' aws" >> /etc/profile.d/tools-completion.sh

# Additional entrypoints
RUN mkdir -p /docker-entrypoint.d
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY scripts/docker-entrypoint.d /docker-entrypoint.d

# Create custom directory for custom-docker-entrypoint.d
RUN mkdir -p /custom-docker-entrypoint.d

# Entrypoint configuration
RUN chmod +x /docker-entrypoint.sh \
  && find /docker-entrypoint.d -type f -exec chmod +x {} +

ENTRYPOINT [ "/docker-entrypoint.sh" ]
CMD [ "bash", "-il" ]
