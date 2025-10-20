.PHONY: create delete install-cert-manager install-otel install-all deploy-collector install-tempo install-prometheus install-grafana install-monitoring install-k6 port-forward-grafana port-forward-prometheus install_brew install_git install_helm install_kubectl install_npm run-app docker-build docker-run docker-check docker-logs docker-remove docker-push docker-pull load-test-install load-test-start kubernetes-context kubernetes-select helm-create helm-install helm-deploy kubernetes-check kubernetes-forward help

# Variables
BREW := brew
DOCKER_IMAGE := thiagousa/password-generator-app:latest
APP_PATH := app/my-app-local/password-generator-app

# Default cluster name
CLUSTER_NAME := otel-demo

# Versions
OTEL_VERSION := 0.93.1
CERTMANAGER_VERSION := v1.18.2
TEMPO_VERSION := 1.23.3
PROMETHEUS_STACK_VERSION := 77.5.0
GRAFANA_VERSION := 9.4.4

# Create the kind cluster
create:
	@echo "Creating Kind cluster: $(CLUSTER_NAME)"
	kind create cluster --config kind-config.yaml
	@echo "Waiting for cluster to be ready..."
	kubectl wait --for=condition=Ready nodes --all --timeout=300s
	@echo "Cluster is ready!"
	kubectl get nodes

# Delete the kind cluster
delete:
	@echo "Deleting Kind cluster: $(CLUSTER_NAME)"
	kind delete cluster --name $(CLUSTER_NAME)
	@echo "Cluster deleted successfully!"

# Install cert-manager
install-cert-manager:
	@echo "Adding jetstack helm repo..."
	helm repo add jetstack https://charts.jetstack.io
	helm repo update
	@echo "Installing cert-manager version $(CERTMANAGER_VERSION)..."
	helm upgrade --install cert-manager jetstack/cert-manager \
		--namespace cert-manager \
		--create-namespace \
		--version $(CERTMANAGER_VERSION) \
		--set crds.enabled=true \
		--set startupapicheck.timeout="5m"
	@echo "Waiting for cert-manager pods to be ready..."
	kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=300s
	kubectl get pods -n cert-manager

# Install OpenTelemetry Operator
install-otel:
	@echo "Adding OpenTelemetry helm repo..."
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
	helm repo update
	@echo "Installing OpenTelemetry Operator version $(OTEL_VERSION)..."
	helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
		--namespace opentelemetry-operator-system \
		--create-namespace \
		--version $(OTEL_VERSION) \
		--values=kubernetes/values.yaml
	@echo "Waiting for OpenTelemetry Operator pods to be ready..."
	kubectl wait --for=condition=Ready pods --all -n opentelemetry-operator-system --timeout=300s
	kubectl get pods -n opentelemetry-operator-system

# Install Tempo
install-tempo:
	@echo "Adding Grafana helm repo..."
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo update
	@echo "Installing Tempo version $(TEMPO_VERSION)..."
	helm upgrade --install tempo grafana/tempo \
		--create-namespace \
		--namespace grafana \
		--version $(TEMPO_VERSION) \
		--values=kubernetes/tempo.yaml
	@echo "Waiting for Tempo pods to be ready..."
	kubectl wait --for=condition=Ready pods --all -n grafana --timeout=300s
	kubectl get pods -n grafana

# Install Prometheus Stack
install-prometheus:
	@echo "Adding Prometheus helm repo..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	@echo "Installing Prometheus Stack version $(PROMETHEUS_STACK_VERSION)..."
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		--version $(PROMETHEUS_STACK_VERSION) \
		--namespace prometheus-operator-system \
		--create-namespace \
		--set prometheusOperator.enabled=true \
		--set prometheusOperator.nodeSelector."kubernetes\.io/os"=linux \
		--set prometheusOperator.fullnameOverride="prometheus-operator" \
		--set prometheusOperator.manageCrds=true \
		--set alertmanager.enabled=false \
		--set grafana.enabled=false \
		--set prometheus-node-exporter.enabled=false \
		--set nodeExporter.enabled=false \
		--set kubeStateMetrics.enabled=false \
		--set prometheus.enabled=false
	@echo "Waiting for Prometheus Operator pods to be ready..."
	kubectl wait --for=condition=Ready pods --all -n prometheus-operator-system --timeout=300s
	kubectl get pods -n prometheus-operator-system
	@echo "Deploying dedicated Prometheus instance..."
	kubectl apply -n monitoring -f kubernetes/prometheus.yaml

# Install Grafana
install-grafana:
	@echo "Installing Grafana version $(GRAFANA_VERSION)..."
	helm upgrade --install grafana grafana/grafana \
		--namespace grafana \
		--version $(GRAFANA_VERSION) \
		--values=kubernetes/grafana.yaml
	@echo "Waiting for Grafana pods to be ready..."
	kubectl wait --for=condition=Ready pods --all -n grafana --timeout=300s
	kubectl get pods -n grafana

# Install k6 Operator for load testing
install-k6:
	@echo "Adding Grafana Helm repo..."
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo update
	@echo "Ensuring k6 operator namespace exists..."
	kubectl create namespace k6-operator-system --dry-run=client -o yaml | kubectl apply -f -
	@echo "Installing k6 operator..."
	helm upgrade --install k6-operator grafana/k6-operator \
		--namespace k6-operator-system
	@echo "Waiting for k6 operator pods to be ready..."
	kubectl wait --for=condition=Ready pods --all -n k6-operator-system --timeout=300s
	kubectl get pods -n k6-operator-system

# Install all monitoring components
install-monitoring: install-tempo install-prometheus install-grafana
	@echo "All monitoring components installed successfully!"

# Install all components
install-all: install-cert-manager install-otel deploy-collector install-monitoring
	@echo "All components installed successfully!"

# Deploy OpenTelemetry Collector
deploy-collector:
	@echo "Creating monitoring namespace..."
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	@echo "Deploying OpenTelemetry Collector..."
	kubectl apply -n monitoring -f kubernetes/collector-tracing.yaml
	@echo "Waiting for collector deployment to be ready..."
	@kubectl wait --for=condition=Available deployment -l app.kubernetes.io/component=opentelemetry-collector -n monitoring --timeout=300s || \
		(echo "Error: Collector deployment not ready. Check the deployment status:" && \
		kubectl get deployments -n monitoring && \
		kubectl get pods -n monitoring && exit 1)
	@echo "Collector deployment completed successfully!"
	kubectl get pods -n monitoring

# Port forward Grafana (http://localhost:3000)
port-forward-grafana:
	@echo "Port forwarding Grafana to http://localhost:3000..."
	@echo "Use ctrl+c to stop port forwarding"
	kubectl -n grafana port-forward svc/grafana 3000:80

# Port forward Prometheus (http://localhost:9090)
port-forward-prometheus:
	@echo "Port forwarding Prometheus to http://localhost:9090..."
	@echo "Use ctrl+c to stop port forwarding"
	kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090

# Development setup commands
install_brew:
	@if ! command -v brew >/dev/null 2>&1; then \
		echo "Homebrew not found. Installing..."; \
		/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; \
	else \
		echo "Homebrew is already installed."; \
	fi

install_git:
	@if ! command -v git >/dev/null 2>&1; then \
		echo "Git not found. Installing..."; \
		$(BREW) install git; \
	else \
		echo "Git is already installed."; \
	fi

install_helm:
	@if ! command -v helm >/dev/null 2>&1; then \
		echo "Helm not found. Installing..."; \
		$(BREW) install helm; \
	else \
		echo "Helm is already installed."; \
	fi

install_kubectl:
	@if ! command -v kubectl >/dev/null 2>&1; then \
		echo "kubectl not found. Installing..."; \
		$(BREW) install kubectl; \
	else \
		echo "kubectl is already installed."; \
	fi

install_npm:
	@if ! command -v npm >/dev/null 2>&1; then \
		echo "npm not found. Installing..."; \
		$(BREW) install npm; \
	else \
		echo "npm is already installed."; \
	fi

# Application commands
run-app:
	cd $(APP_PATH) && \
	if [ ! -f .env ]; then \
		mv data .env; \
	fi && \
	npm install && npm start

# Docker commands
docker-build:
	docker buildx build --platform linux/amd64,linux/arm64 -t $(DOCKER_IMAGE) $(APP_PATH)

docker-run:
	docker run -itd -p 3000:3000 --name=password $(DOCKER_IMAGE)

docker-check:
	docker ps | grep -i password

docker-logs:
	docker logs -f password

docker-remove:
	docker rm password --force

docker-push:
	docker push $(DOCKER_IMAGE)

docker-pull:
	docker pull $(DOCKER_IMAGE)

# Load testing commands
load-test-install:
	npm install -g artillery

load-test-start:
	artillery run $(APP_PATH)/loadtest/loadtest.yaml

# Kubernetes commands
kubernetes-context:
	kubectl config get-contexts

kubernetes-select:
	kubectl config use-context kind-otel-demo 

kubernetes-check:
	kubectl get pods

kubernetes-forward:
	kubectl port-forward svc/password-generator-app 3000:3000

# Helm commands
helm-create:
	helm create $(APP_PATH)-helm

helm-install:
	helm upgrade --install password-generator-app app/password-generator-app

helm-deploy:
	helm template password-generator-app app/password-generator-app > deployment.yaml

# Show help
help:
	@echo "Available commands:"
	@echo ""
	@echo "Cluster and Monitoring:"
	@echo "  make create              - Create the kind cluster using kind-config.yaml"
	@echo "  make delete             - Delete the kind cluster"
	@echo "  make install-cert-manager - Install cert-manager"
	@echo "  make install-otel        - Install OpenTelemetry Operator"
	@echo "  make deploy-collector    - Deploy OpenTelemetry Collector to monitoring namespace"
	@echo "  make install-tempo       - Install Tempo for distributed tracing"
	@echo "  make install-prometheus  - Install Prometheus Stack and dedicated Prometheus"
	@echo "  make install-grafana     - Install Grafana for dashboards"
	@echo "  make install-k6          - Install k6 operator for Kubernetes load testing"
	@echo "  make install-monitoring  - Install all monitoring components (Tempo, Prometheus, Grafana)"
	@echo "  make install-all         - Install everything (cert-manager, OpenTelemetry, collector, monitoring)"
	@echo "  make port-forward-grafana - Access Grafana UI at http://localhost:3000"
	@echo "  make port-forward-prometheus - Access Prometheus UI at http://localhost:9090"
	@echo ""
	@echo "Development Setup:"
	@echo "  make install_brew       - Install Homebrew"
	@echo "  make install_git        - Install Git"
	@echo "  make install_helm       - Install Helm"
	@echo "  make install_kubectl    - Install kubectl"
	@echo "  make install_npm        - Install npm"
	@echo ""
	@echo "Application:"
	@echo "  make run-app            - Run the password generator app locally"
	@echo ""
	@echo "Docker:"
	@echo "  make docker-build       - Build the Docker image"
	@echo "  make docker-run         - Run the Docker container"
	@echo "  make docker-check       - Check running container"
	@echo "  make docker-logs        - View container logs"
	@echo "  make docker-remove      - Remove the container"
	@echo "  make docker-push        - Push image to Docker Hub"
	@echo "  make docker-pull        - Pull image from Docker Hub"
	@echo ""
	@echo "Load Testing:"
	@echo "  make load-test-install  - Install Artillery for load testing"
	@echo "  make load-test-start    - Run load tests"
	@echo ""
	@echo "Kubernetes:"
	@echo "  make kubernetes-context - Show Kubernetes contexts"
	@echo "  make kubernetes-select  - Select Rancher Desktop context"
	@echo "  make kubernetes-check   - Check running pods"
	@echo "  make kubernetes-forward - Port forward the application"
	@echo ""
	@echo "Helm:"
	@echo "  make helm-create       - Create new Helm chart"
	@echo "  make helm-install      - Install Helm chart"
	@echo "  make helm-deploy       - Generate deployment manifest"
	@echo ""
	@echo "Help:"
	@echo "  make help             - Show this help message"
