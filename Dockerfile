FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    jq \
    bash \
    gnupg \
    lsb-release \
    apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl" -o /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/kubectl

RUN curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.48.1/yq_linux_$(dpkg --print-architecture) -o /usr/local/bin/yq \
  && chmod +x /usr/local/bin/yq

RUN arch=$([[ `dpkg --print-architecture` == "amd64" ]] && echo x86_64 || echo arm64) \
  && echo arch is ${arch} \
  && curl -LO https://github.com/kyverno/kyverno/releases/download/v1.15.2/kyverno-cli_v1.15.2_linux_${arch}.tar.gz \
  && tar -xvf kyverno-cli_v1.15.2_linux_${arch}.tar.gz \
  && cp kyverno /usr/local/bin/ \
  && chmod +x /usr/local/bin/kyverno

RUN rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
