FROM debian:bullseye
# Note: "bullseye" is currently the "testing" version of debian, it is not considered stable...

ARG AWSCLI_VERSION=1.18.17
ARG AZURECLI_VERSION=2.7.0-1
ARG CLOUD_SDK_VERSION=295.0.0
ARG HELM_VERSION=v3.2.2
ARG HELM_DIFF_VERSION=v3.1.1
ARG KOPS_VERSION=v1.17.0
ARG KUBECTL_VERSION=v1.18.3
ARG TERRAFORM_VERSION=0.12.28
ARG ISTIO_VERSION=1.6.4
ARG YQ_VERSION=2.10.1
ARG JSONNET_VERSION=0.16.0

# Some required tools
RUN apt-get update && apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gettext \
  git \
  gnupg \
  jq \
  jsonnet \
  lsb-release \
  python3 \
  python3-pip \
  wget \
  unzip

# Google Cloud SDK install
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
  apt-get update && apt-get install -y google-cloud-sdk=${CLOUD_SDK_VERSION}-0

# AWS cli install
RUN pip3 install awscli==${AWSCLI_VERSION}

# Azure cli install
# Note: we force the download of the package for the older Debian "buster" instead of "bullseye" (that would be returned by `lsb_release -cs`),
# because it is not currently available for this debian release
RUN echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ buster main" | tee /etc/apt/sources.list.d/azure-cli.list && \
  curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/trusted.gpg.d/microsoft.asc.gpg > /dev/null && \
  apt-get update && apt-get install -y azure-cli=${AZURECLI_VERSION}~buster

# Python dependencies
RUN pip3 install kubernetes==11.0.0

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
RUN curl -L https://istio.io/downloadIstio | sh -
RUN mv ./istio-${ISTIO_VERSION}/bin/* /usr/local/bin/

# yq install
RUN pip3 install yq==${YQ_VERSION}

COPY getconfig.sh         /usr/bin/quortex/getconfig
COPY pushconfig.sh        /usr/bin/quortex/pushconfig
COPY update_segmenter.py  /usr/bin/quortex/updatesegmenter

ENV PATH=$PATH:/usr/bin/quortex/

ENTRYPOINT []
