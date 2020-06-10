FROM debian:buster

ARG AWSCLI_VERSION=1.18.17
ARG CLOUD_SDK_VERSION=295.0.0
ARG KUBECTL_VERSION=v1.18.3

# Some required tools
RUN apt-get update && apt-get install -y \
  apt-transport-https \
  ca-certificates \
  gettext \
  gnupg \
  jq \
  python3 \
  python3-pip

# Google Cloud SDK install
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
  apt-get update && apt-get install -y google-cloud-sdk=${CLOUD_SDK_VERSION}-0

# AWS cli install
RUN pip3 install awscli==${AWSCLI_VERSION}

# Python dependencies
RUN pip3 install kubernetes==11.0.0

# kubectl install
RUN curl -LO https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl
RUN chmod +x ./kubectl
RUN mv ./kubectl /usr/local/bin/kubectl

COPY getconfig.sh   /usr/bin/quortex/getconfig
COPY pushconfig.sh  /usr/bin/quortex/pushconfig
COPY update_segmenter.py /usr/bin/quortex/update_segmenter
ENV PATH=$PATH:/usr/bin/quortex/

RUN env
ENTRYPOINT ["/bin/bash"]
