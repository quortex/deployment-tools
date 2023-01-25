FROM debian:buster

ARG AWSCLI_VERSION=1.25.38
ARG AZURECLI_VERSION=2.17.1
ARG CLOUD_SDK_VERSION=336.0.0
ARG HELM_VERSION=v3.8.2
ARG HELM_DIFF_VERSION=v3.4.2
ARG ISTIOCTL_VERSION=1.16.1
ARG JSONNET_VERSION=v0.17.0
ARG KOPS_VERSION=v1.18.2
ARG KUBECTL_VERSION=v1.20.1
ARG KUSTOMIZE_VERSION=v3.9.1
ARG TERRAFORM_VERSION=0.14.11
ARG YQ_VERSION=2.11.1
ARG ANSIBLE_VERSION=2.9.23

# Some required tools
RUN apt-get update && apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gettext \
  git \
  gnupg \
  jq \
  lsb-release \
  python3 \
  libffi-dev \
  python3-pip \
  wget \
  unzip \
  vim \
  bc

# Google Cloud SDK install
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
  apt-get update && apt-get install -y google-cloud-sdk=${CLOUD_SDK_VERSION}-0

# AWS cli install
RUN pip3 install awscli==${AWSCLI_VERSION}

# Azure cli install
RUN pip3 install azure-cli==${AZURECLI_VERSION}

# Python dependencies
RUN pip3 install kubernetes==11.0.0

# Ansible install
RUN pip3 install ansible==${ANSIBLE_VERSION}

# kubectl install
RUN curl -LO https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl && \
  chmod +x ./kubectl && \
  mv ./kubectl /usr/local/bin/kubectl

# KOPS install
RUN curl -Lo kops https://github.com/kubernetes/kops/releases/download/${KOPS_VERSION}/kops-linux-amd64 && \
  chmod +x ./kops && \
  mv ./kops /usr/local/bin/

# terraform install
RUN wget https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
  unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
  rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
  mv ./terraform /usr/local/bin/

# helm install
RUN wget https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz && \
  tar -zxvf helm-${HELM_VERSION}-linux-amd64.tar.gz && \
  rm helm-${HELM_VERSION}-linux-amd64.tar.gz && \
  mv linux-amd64/helm /usr/local/bin/helm

# helm plugins install
RUN helm plugin install https://github.com/databus23/helm-diff --version ${HELM_DIFF_VERSION}

# Istioctl install
RUN curl -fsLO https://github.com/istio/istio/releases/download/${ISTIOCTL_VERSION}/istioctl-${ISTIOCTL_VERSION}-linux-amd64.tar.gz && \
  tar -zxvf istioctl-${ISTIOCTL_VERSION}-linux-amd64.tar.gz && \
  rm istioctl-${ISTIOCTL_VERSION}-linux-amd64.tar.gz && \
  mv ./istioctl /usr/local/bin/

# yq install
RUN pip3 install yq==${YQ_VERSION}

# jsonnet install
RUN wget https://github.com/google/jsonnet/releases/download/${JSONNET_VERSION}/jsonnet-bin-${JSONNET_VERSION}-linux.tar.gz \
  && tar xzf jsonnet-bin-${JSONNET_VERSION}-linux.tar.gz -C /usr/local/bin/ jsonnet \
  && rm jsonnet-bin-${JSONNET_VERSION}-linux.tar.gz

# kustomize install
RUN curl -fsLO https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz && \
  tar -zxvf kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz && \
  rm kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz && \
  mv ./kustomize /usr/local/bin/

COPY getconfig.sh                               /usr/bin/quortex/getconfig
COPY pushconfig.sh                              /usr/bin/quortex/pushconfig
COPY update_segmenter.py                        /usr/bin/quortex/updatesegmenter
COPY enable_distribution_additional_metrics.py  /usr/bin/quortex/enable_distribution_additional_metrics.py
COPY drainnodes.sh                              /usr/bin/quortex/drainnodes

ENV PATH=$PATH:/usr/bin/quortex/

ENTRYPOINT []
